//+------------------------------------------------------------------+
//|                                              Trading/TradeZone.mqh |
//+------------------------------------------------------------------+
#ifndef TRADEZONE_MQH
#define TRADEZONE_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../Core/RuntimeParameters.mqh"
#include "../Analysis/TFContext.mqh"
#include "../Analysis/Scoring.mqh"
#include "Targets.mqh"

class CTradeDecision
  {
private:
   CCandleData*      m_priceRef;
   CTFContext*       m_fvgCtx;
   CTFContext*       m_liqCtx;
   CScoringEngine*   m_scoring;
   TradeSetup        m_lastSetup;
   double            m_slBufferATR;
   double            m_minStopSpreadMult;
   double            m_fvgMaxDistATR;
   bool              m_runtimeEnabled;
   RuntimeParameters m_runtime;

   bool              FindEntryFVG(ENUM_FVG_DIR dir, FVGZone &out);
   double            EnforceSpreadFloor(string symbol, double entry, double stopLoss, bool isBuy);
   double            RuntimeStrategyThreshold(const TradeSetup &setup);
   double            RuntimeContradictionPenalty(const SetupReasons &r);
   void              ApplyRuntimeOverlay(TradeSetup &setup);

public:
                     CTradeDecision();
   void              Init(CCandleData* priceRef, CTFContext* fvgCtx, CTFContext* liqCtx, CScoringEngine* scoring,
                          double slBufferATR = 0.25, double minStopSpreadMult = 3.0);
   void              ApplyRuntimeParameters(const RuntimeParameters &parameters);
   TradeSetup        GenerateBuySetup();
   TradeSetup        GenerateSellSetup();
   TradeSetup        GetLastSetup() const { return m_lastSetup; }
  };

CTradeDecision::CTradeDecision()
  {
   ZeroMemory(m_lastSetup);
   m_slBufferATR = 0.25;
   m_minStopSpreadMult = 3.0;
   m_fvgMaxDistATR = 3.0;
   m_runtimeEnabled = false;
   m_runtime.Defaults();
  }

void CTradeDecision::Init(CCandleData* priceRef, CTFContext* fvgCtx, CTFContext* liqCtx, CScoringEngine* scoring,
                          double slBufferATR, double minStopSpreadMult)
  {
   m_priceRef = priceRef;
   m_fvgCtx = fvgCtx;
   m_liqCtx = liqCtx;
   m_scoring = scoring;
   m_slBufferATR = (slBufferATR > 0.0 ? slBufferATR : 0.25);
   m_minStopSpreadMult = (minStopSpreadMult >= 0.0 ? minStopSpreadMult : 3.0);
  }

void CTradeDecision::ApplyRuntimeParameters(const RuntimeParameters &parameters)
  {
   // ConfigSync has already performed range validation. Copying the whole
   // struct is atomic at the application boundary; no partial parameter set
   // can be observed by Generate*Setup().
   m_runtime = parameters;
   m_runtimeEnabled = true;
   m_fvgMaxDistATR = parameters.fvg_proximity_atr;
  }

// Widens (never tightens) a stop so its distance from the real execution
// entry is at least (current spread * m_minStopSpreadMult).
double CTradeDecision::EnforceSpreadFloor(string symbol, double entry, double stopLoss, bool isBuy)
  {
   if(m_minStopSpreadMult <= 0.0) return stopLoss;
   long spreadPoints = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(spreadPoints <= 0 || point <= 0) return stopLoss;
   double minDist = spreadPoints * point * m_minStopSpreadMult;
   double curDist = MathAbs(entry - stopLoss);
   if(curDist >= minDist) return stopLoss;
   return isBuy ? (entry - minDist) : (entry + minDist);
  }

bool CTradeDecision::FindEntryFVG(ENUM_FVG_DIR dir, FVGZone &out)
  {
   if(m_fvgCtx == NULL || m_priceRef == NULL || m_priceRef.Total() == 0) return false;
   double price = m_priceRef.GetCandle(0).close;
   double atr = m_fvgCtx.candles.GetATR(0);
   if(atr <= 0) return false;

   for(int i = 0; i < m_fvgCtx.fvg.Count(); i++)
     {
      FVGZone z = m_fvgCtx.fvg.GetZone(i);
      if(z.dir != dir) continue;
      if(z.state != FVG_FRESH && z.state != FVG_TESTED) continue;
      double mid = (z.top + z.bottom) / 2.0;
      if(MathAbs(price - mid) / atr > m_fvgMaxDistATR) continue;
      out = z;
      return true;
     }
   return false;
  }

double CTradeDecision::RuntimeStrategyThreshold(const TradeSetup &setup)
  {
   if(!m_runtimeEnabled) return 60.0;
   double threshold = (double)m_runtime.ensemble_threshold;
   switch(setup.reasons.selected_strategy)
     {
      case STRATEGY_MOMENTUM_BREAKOUT:
         threshold = MathMax(threshold, (double)m_runtime.momentum_threshold);
         break;
      case STRATEGY_MEAN_REVERSION:
         threshold = MathMax(threshold, (double)m_runtime.mean_reversion_threshold);
         break;
      case STRATEGY_KEY_LEVEL:
         threshold = MathMax(threshold, (double)m_runtime.key_level_threshold);
         break;
      case STRATEGY_SMC:
         threshold = MathMax(threshold, (double)m_runtime.smc_threshold);
         break;
      default:
         threshold = MathMax(threshold, (double)m_runtime.smc_threshold);
         break;
     }
   return threshold;
  }

double CTradeDecision::RuntimeContradictionPenalty(const SetupReasons &r)
  {
   if(!m_runtimeEnabled) return 0.0;
   int hits = 0;
   if(!r.trend_aligned)               hits++;
   if(!r.premium_discount_ok)         hits++;
   if(!r.chase_ok)                    hits++;
   if(r.vol_regime == VOL_REGIME_LOW) hits++;
   if(!r.session_ok)                  hits++;
   if(r.news_risk != NEWS_NONE)       hits++;
   if(r.htf_ob_state == OB_MITIGATED) hits++;
   return MathMin((double)hits * m_runtime.contradiction_penalty, 1.0);
  }

void CTradeDecision::ApplyRuntimeOverlay(TradeSetup &setup)
  {
   if(!m_runtimeEnabled) return;

   // Runtime parameters are an overlay on the compiled analysis engine.
   // The expensive detectors still run once; this step is only scalar math.
   double contradiction = RuntimeContradictionPenalty(setup.reasons);
   setup.confidence *= (1.0 - contradiction);

   double required = RuntimeStrategyThreshold(setup);
   if(setup.confidence < required)
      setup.active = false;
  }

TradeSetup CTradeDecision::GenerateBuySetup()
  {
   TradeSetup setup;
   ZeroMemory(setup);
   if(m_priceRef == NULL || m_fvgCtx == NULL || m_scoring == NULL) return setup;

   double conf = m_scoring.CalculateConfidence(true);
   if(conf < 50.0) return setup;

   FVGZone entryFVG;
   if(!FindEntryFVG(FVG_BULL, entryFVG)) return setup;

   double atr = m_fvgCtx.candles.GetATR(0);
   if(atr <= 0) return setup;

   setup.type = ORDER_TYPE_BUY;
   setup.entry_top = entryFVG.top;
   setup.entry_bottom = entryFVG.bottom;
   setup.stop_loss = entryFVG.bottom - m_slBufferATR * atr;
   setup.stop_loss = EnforceSpreadFloor(m_priceRef.Symbol(), setup.entry_top, setup.stop_loss, true);
   CTargetSelector::AssignTargets(setup, m_liqCtx, m_priceRef.Symbol(), atr, setup.entry_bottom);
   setup.confidence = conf;
   setup.creation_time = TimeCurrent();
   setup.active = true;
   m_scoring.EvaluateReasons(true, setup.reasons);
   m_scoring.PopulateStrategyDiagnostics(true, setup.confidence, setup.reasons);
   ApplyRuntimeOverlay(setup);
   m_scoring.PopulateConfidenceDiagnostics(setup.reasons, setup.confidence);
   m_lastSetup = setup;
   return setup;
  }

TradeSetup CTradeDecision::GenerateSellSetup()
  {
   TradeSetup setup;
   ZeroMemory(setup);
   if(m_priceRef == NULL || m_fvgCtx == NULL || m_scoring == NULL) return setup;

   double conf = m_scoring.CalculateConfidence(false);
   if(conf < 50.0) return setup;

   FVGZone entryFVG;
   if(!FindEntryFVG(FVG_BEAR, entryFVG)) return setup;

   double atr = m_fvgCtx.candles.GetATR(0);
   if(atr <= 0) return setup;

   setup.type = ORDER_TYPE_SELL;
   setup.entry_top = entryFVG.top;
   setup.entry_bottom = entryFVG.bottom;
   setup.stop_loss = entryFVG.top + m_slBufferATR * atr;
   setup.stop_loss = EnforceSpreadFloor(m_priceRef.Symbol(), setup.entry_bottom, setup.stop_loss, false);
   CTargetSelector::AssignTargets(setup, m_liqCtx, m_priceRef.Symbol(), atr, setup.entry_top);
   setup.confidence = conf;
   setup.creation_time = TimeCurrent();
   setup.active = true;
   m_scoring.EvaluateReasons(false, setup.reasons);
   m_scoring.PopulateStrategyDiagnostics(false, setup.confidence, setup.reasons);
   ApplyRuntimeOverlay(setup);
   m_scoring.PopulateConfidenceDiagnostics(setup.reasons, setup.confidence);
   m_lastSetup = setup;
   return setup;
  }
#endif
//+------------------------------------------------------------------+
