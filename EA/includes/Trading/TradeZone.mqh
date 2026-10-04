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
   double            m_targetMinRR;
   bool              m_runtimeEnabled;
   RuntimeParameters m_runtime;

   double            EnforceSpreadFloor(string symbol, double entry, double stopLoss, bool isBuy);

public:
                     CTradeDecision();
   void              Init(CCandleData* priceRef, CTFContext* fvgCtx, CTFContext* liqCtx, CScoringEngine* scoring,
                          CStructuralValidator* validator, double slBufferATR = 0.25, double minStopSpreadMult = 3.0,
                          double targetMinRR = 1.5);
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
   m_targetMinRR = 1.5;
   m_runtimeEnabled = false;
   m_runtime.Defaults();
   m_validator = NULL;
   BindRuntimeConfigConsumer(this);
  }

void CTradeDecision::Init(CCandleData* priceRef, CTFContext* fvgCtx, CTFContext* liqCtx, CScoringEngine* scoring,
                          CStructuralValidator* validator, double slBufferATR, double minStopSpreadMult,
                          double targetMinRR)
  {
   m_priceRef = priceRef;
   m_fvgCtx = fvgCtx;
   m_liqCtx = liqCtx;
   m_scoring = scoring;
   m_validator = validator;
   m_slBufferATR = (slBufferATR > 0.0 ? slBufferATR : 0.25);
   m_minStopSpreadMult = (minStopSpreadMult >= 0.0 ? minStopSpreadMult : 3.0);
   m_targetMinRR = (targetMinRR > 0.0 ? targetMinRR : 1.5);
  }

void CTradeDecision::ApplyRuntimeParameters(const RuntimeParameters &parameters)
  {
   m_runtime = parameters;
   m_runtimeEnabled = true;
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


TradeSetup CTradeDecision::GenerateBuySetup()
  {
   TradeSetup setup;
   ZeroMemory(setup);
   if(m_priceRef == NULL || m_fvgCtx == NULL || m_scoring == NULL || m_validator == NULL)
      return setup;

   StructuralValidationResult sv;
   if(!m_validator.Validate(true, sv))
      return setup;

   string regimeReason;
   if(!m_scoring.IsRegimeCompatible(true, sv.family, regimeReason))
      return setup;

   double conf = m_scoring.CalculateConfidence(true);
   if(conf < 50.0) return setup;

   double atr = m_fvgCtx.candles.GetATR(1);
   if(atr <= 0.0) return setup;

   setup.setup_id = sv.chain.chain_key;
   setup.smc_chain_id = sv.chain.chain_id;
   setup.status = SETUP_ACTIVE;
   setup.rejection_reason = SETUP_REJECT_NONE;
   setup.family = sv.family;
   setup.type = ORDER_TYPE_BUY;
   setup.entry_top = sv.entry_fvg.top;
   setup.entry_bottom = sv.entry_fvg.bottom;
   setup.invalidation = sv.invalidation_price;
   setup.stop_loss = setup.invalidation - m_slBufferATR * atr;
   setup.stop_loss = EnforceSpreadFloor(m_priceRef.Symbol(), setup.entry_top, setup.stop_loss, true);

   CTargetSelector::AssignTargets(setup, m_liqCtx, m_priceRef.Symbol(), atr,
                                  ResolveExecutionEntry(setup),
                                  m_targetMinRR, m_scoring.GetMarketRegime());

   // Targets are part of the executable contract, not presentation. Do not
   // let an unvalidated/fallback target ladder proceed to logging, persistence,
   // or execution; RiskEngine repeats this gate later as defense in depth.
   if(!setup.target_plan_valid)
      return setup;

   setup.raw_confidence = conf;
   setup.confidence = conf;
   setup.structural_valid = sv.valid;
   setup.structural_quality = sv.structural_quality;
   setup.creation_time = sv.chain.has_choch ? sv.chain.choch.time : sv.chain.bos.time;
   setup.expiry_time = 0;
   setup.active = true;

   m_scoring.EvaluateReasons(true, setup.reasons);
   setup.reasons.regime_compatible = true;
   setup.reasons.regime_reason = regimeReason;
   setup.reasons.regime_quality = m_scoring.GetRegimeQuality();
   setup.reasons.regime_age_bars = m_scoring.GetRegimeAgeBars();
   setup.reasons.bos_confirmed = (sv.chain.has_bos || sv.chain.has_choch);
   setup.reasons.liquidity_swept = sv.chain.has_sweep;
   setup.reasons.fresh_fvg = true;
   setup.reasons.ifvg_confirmed = sv.extensions.ifvg_confirmed;
   setup.reasons.bpr_confirmed = sv.extensions.bpr_confirmed;
   setup.reasons.cisd_confirmed = sv.extensions.cisd_confirmed;
   setup.reasons.breaker_block_confirmed = sv.extensions.breaker_block_confirmed;
   setup.reasons.smt_confirmed = sv.extensions.smt_confirmed;
   setup.reasons.extension_quality = sv.extensions.combined_quality;
   m_scoring.PopulateStrategyDiagnostics(true, setup.confidence, setup.reasons);
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

   string regimeReason;
   if(!m_scoring.IsRegimeCompatible(false, sv.family, regimeReason))
      return setup;

   double conf = m_scoring.CalculateConfidence(false);
   if(conf < 50.0) return setup;

   double atr = m_fvgCtx.candles.GetATR(1);
   if(atr <= 0.0) return setup;

   setup.setup_id = sv.chain.chain_key;
   setup.smc_chain_id = sv.chain.chain_id;
   setup.status = SETUP_ACTIVE;
   setup.rejection_reason = SETUP_REJECT_NONE;
   setup.family = sv.family;
   setup.type = ORDER_TYPE_SELL;
   setup.entry_top = sv.entry_fvg.top;
   setup.entry_bottom = sv.entry_fvg.bottom;
   setup.invalidation = sv.invalidation_price;
   setup.stop_loss = setup.invalidation + m_slBufferATR * atr;
   setup.stop_loss = EnforceSpreadFloor(m_priceRef.Symbol(), setup.entry_bottom, setup.stop_loss, false);

   CTargetSelector::AssignTargets(setup, m_liqCtx, m_priceRef.Symbol(), atr,
                                  ResolveExecutionEntry(setup),
                                  m_targetMinRR, m_scoring.GetMarketRegime());

   setup.raw_confidence = conf;
   setup.confidence = conf;
   setup.structural_valid = sv.valid;
   setup.structural_quality = sv.structural_quality;
   setup.creation_time = sv.chain.has_choch ? sv.chain.choch.time : sv.chain.bos.time;
   setup.expiry_time = 0;
   setup.active = true;

   m_scoring.EvaluateReasons(false, setup.reasons);
   setup.reasons.regime_compatible = true;
   setup.reasons.regime_reason = regimeReason;
   setup.reasons.regime_quality = m_scoring.GetRegimeQuality();
   setup.reasons.regime_age_bars = m_scoring.GetRegimeAgeBars();
   setup.reasons.bos_confirmed = (sv.chain.has_bos || sv.chain.has_choch);
   setup.reasons.liquidity_swept = sv.chain.has_sweep;
   setup.reasons.fresh_fvg = true;
   setup.reasons.ifvg_confirmed = sv.extensions.ifvg_confirmed;
   setup.reasons.bpr_confirmed = sv.extensions.bpr_confirmed;
   setup.reasons.cisd_confirmed = sv.extensions.cisd_confirmed;
   setup.reasons.breaker_block_confirmed = sv.extensions.breaker_block_confirmed;
   setup.reasons.smt_confirmed = sv.extensions.smt_confirmed;
   setup.reasons.extension_quality = sv.extensions.combined_quality;
   m_scoring.PopulateStrategyDiagnostics(false, setup.confidence, setup.reasons);
   m_scoring.PopulateConfidenceDiagnostics(setup.reasons, setup.confidence);

   m_lastSetup = setup;
   return setup;
  }

#endif
//+------------------------------------------------------------------+
