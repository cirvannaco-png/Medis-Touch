//+------------------------------------------------------------------+
//|                                              Trading/TradeZone.mqh |
//+------------------------------------------------------------------+
#ifndef TRADEZONE_MQH
#define TRADEZONE_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../Core/RuntimeParameters.mqh"
#include "../Core/RuntimeConfigBus.mqh"
#include "../Analysis/TFContext.mqh"
#include "../Analysis/Scoring.mqh"
#include "../Analysis/StructuralValidator.mqh"
#include "Targets.mqh"

class CTradeDecision : public IRuntimeConfigConsumer
  {
private:
   CCandleData*      m_priceRef;
   CTFContext*       m_fvgCtx;
   CTFContext*       m_liqCtx;
   CScoringEngine*      m_scoring;
   CStructuralValidator* m_validator;
   TradeSetup             m_lastSetup;
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
                          CStructuralValidator* validator, double slBufferATR = 0.25, double minStopSpreadMult = 3.0);
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
   m_validator = NULL;
   BindRuntimeConfigConsumer(this);
  }

void CTradeDecision::Init(CCandleData* priceRef, CTFContext* fvgCtx, CTFContext* liqCtx, CScoringEngine* scoring,
                          CStructuralValidator* validator, double slBufferATR, double minStopSpreadMult)
  {
   m_priceRef = priceRef;
   m_fvgCtx = fvgCtx;
   m_liqCtx = liqCtx;
   m_scoring = scoring;
   m_validator = validator;
   m_slBufferATR = (slBufferATR > 0.0 ? slBufferATR : 0.25);
   m_minStopSpreadMult = (minStopSpreadMult >= 0.0 ? minStopSpreadMult : 3.0);
  }

void CTradeDecision::ApplyRuntimeParameters(const RuntimeParameters &parameters)
  {
   m_runtime = parameters;
   m_runtimeEnabled = true;
   m_fvgMaxDistATR = parameters.fvg_proximity_atr;
  }

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
   // v2.16: runtime configuration is policy metadata only until the
   // DecisionEngine owns an explicit, auditable policy record. The former
   // implementation mutated setup.active/confidence and read the diagnostic
   // strategy selector, making a supposedly diagnostic module live.
   setup.active = setup.active;
  }


TradeSetup CTradeDecision::GenerateBuySetup()
  {
   TradeSetup setup;
   ZeroMemory(setup);
   if(m_priceRef == NULL || m_fvgCtx == NULL || m_scoring == NULL || m_validator == NULL)
      return setup;

   StructuralValidationResult sv;
   if(!m_validator.Validate(true, sv))
      return setup;

   double conf = m_scoring.CalculateConfidence(true);
   if(conf < 50.0) return setup;

   double atr = m_fvgCtx.candles.GetATR(1);
   if(atr <= 0.0) return setup;

   setup.setup_id = sv.chain.chain_key;
   setup.smc_chain_id = sv.chain.chain_id;
   setup.status = SETUP_ACTIVE;
   setup.rejection_reason = SETUP_REJECT_NONE;
   setup.type = ORDER_TYPE_BUY;
   setup.entry_top = sv.entry_fvg.top;
   setup.entry_bottom = sv.entry_fvg.bottom;
   setup.invalidation = sv.invalidation_price;
   setup.stop_loss = setup.invalidation - m_slBufferATR * atr;
   setup.stop_loss = EnforceSpreadFloor(m_priceRef.Symbol(), setup.entry_top, setup.stop_loss, true);

   CTargetSelector::AssignTargets(setup, m_liqCtx, m_priceRef.Symbol(), atr, setup.entry_bottom);

   setup.raw_confidence = conf;
   setup.confidence = conf;
   setup.structural_valid = sv.valid;
   setup.structural_quality = sv.structural_quality;
   setup.creation_time = sv.chain.has_choch ? sv.chain.choch.time : sv.chain.bos.time;
   setup.expiry_time = 0;
   setup.active = true;

   m_scoring.EvaluateReasons(true, setup.reasons);
   setup.reasons.bos_confirmed = true;
   setup.reasons.liquidity_swept = sv.chain.has_sweep;
   setup.reasons.fresh_fvg = true;
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
   if(m_priceRef == NULL || m_fvgCtx == NULL || m_scoring == NULL || m_validator == NULL)
      return setup;

   StructuralValidationResult sv;
   if(!m_validator.Validate(false, sv))
      return setup;

   double conf = m_scoring.CalculateConfidence(false);
   if(conf < 50.0) return setup;

   double atr = m_fvgCtx.candles.GetATR(1);
   if(atr <= 0.0) return setup;

   setup.setup_id = sv.chain.chain_key;
   setup.smc_chain_id = sv.chain.chain_id;
   setup.status = SETUP_ACTIVE;
   setup.rejection_reason = SETUP_REJECT_NONE;
   setup.type = ORDER_TYPE_SELL;
   setup.entry_top = sv.entry_fvg.top;
   setup.entry_bottom = sv.entry_fvg.bottom;
   setup.invalidation = sv.invalidation_price;
   setup.stop_loss = setup.invalidation + m_slBufferATR * atr;
   setup.stop_loss = EnforceSpreadFloor(m_priceRef.Symbol(), setup.entry_bottom, setup.stop_loss, false);

   CTargetSelector::AssignTargets(setup, m_liqCtx, m_priceRef.Symbol(), atr, setup.entry_top);

   setup.raw_confidence = conf;
   setup.confidence = conf;
   setup.structural_valid = sv.valid;
   setup.structural_quality = sv.structural_quality;
   setup.creation_time = sv.chain.has_choch ? sv.chain.choch.time : sv.chain.bos.time;
   setup.expiry_time = 0;
   setup.active = true;

   m_scoring.EvaluateReasons(false, setup.reasons);
   setup.reasons.bos_confirmed = true;
   setup.reasons.liquidity_swept = sv.chain.has_sweep;
   setup.reasons.fresh_fvg = true;
   m_scoring.PopulateStrategyDiagnostics(false, setup.confidence, setup.reasons);
   ApplyRuntimeOverlay(setup);
   m_scoring.PopulateConfidenceDiagnostics(setup.reasons, setup.confidence);

   m_lastSetup = setup;
   return setup;
  }

#endif
//+------------------------------------------------------------------+
