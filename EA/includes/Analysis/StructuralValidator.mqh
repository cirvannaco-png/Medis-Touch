//+------------------------------------------------------------------+
//|                                    Analysis/StructuralValidator.mqh |
//|  Single hard structural gate for Midas-Touch2 (v2.16).             |
//+------------------------------------------------------------------+
#ifndef STRUCTURALVALIDATOR_MQH
#define STRUCTURALVALIDATOR_MQH

#include "SMCChain.mqh"

struct StructuralValidationResult
  {
   bool                        valid;
   ENUM_SETUP_REJECTION_REASON rejection_reason;

   ENUM_SETUP_FAMILY            family;
   ENUM_ORDER_TYPE              direction;

   SMCChain                    chain;
   FVGZone                     entry_fvg;

   bool   htf_aligned;
   bool   htf_conflict;

   double structural_quality;
   double invalidation_price;

   datetime validated_time;
   string reason;
  };

class CStructuralValidator
  {
private:
   CSMCChainBuilder m_builder;
   CTFContext*      m_htfCtx;
   bool             m_requireContinuationHTFAlignment;
   double           m_minContinuationHTFTrend;

   bool ValidateHTF(bool forBuy, ENUM_SETUP_FAMILY family,
                    bool &aligned, bool &conflict, string &reason);

   ENUM_SETUP_REJECTION_REASON MapChainFailure(const SMCChain &chain) const;

public:
   CStructuralValidator();

   void Init(CTFContext* entryCtx,
             CTFContext* htfCtx,
             int maxSweepToStructureBars = 8,
             int maxStructureToFVGBars = 2,
             int maxFVGAgeBars = 15,
             double minDisplacementATR = 1.0,
             double minDisplacementBodyRatio = 0.55,
             double minStructureStrength = 0.45,
             bool requirePremiumDiscount = true,
             bool requireContinuationHTFAlignment = true,
             double minContinuationHTFTrendStrength = 0.0);

   bool Validate(bool forBuy, StructuralValidationResult &out);
  };

CStructuralValidator::CStructuralValidator()
  : m_htfCtx(NULL),
    m_requireContinuationHTFAlignment(true),
    m_minContinuationHTFTrend(0.0)
  {}

void CStructuralValidator::Init(CTFContext* entryCtx,
                                CTFContext* htfCtx,
                                int maxSweepToStructureBars,
                                int maxStructureToFVGBars,
                                int maxFVGAgeBars,
                                double minDisplacementATR,
                                double minDisplacementBodyRatio,
                                double minStructureStrength,
                                bool requirePremiumDiscount,
                                bool requireContinuationHTFAlignment,
                                double minContinuationHTFTrendStrength)
  {
   m_htfCtx = htfCtx;
   m_requireContinuationHTFAlignment = requireContinuationHTFAlignment;
   m_minContinuationHTFTrend = MathMax(0.0, MathMin(1.0, minContinuationHTFTrend));

   m_builder.Init(entryCtx,
                  maxSweepToStructureBars,
                  maxStructureToFVGBars,
                  maxFVGAgeBars,
                  minDisplacementATR,
                  minDisplacementBodyRatio,
                  minStructureStrength,
                  requirePremiumDiscount);
  }

ENUM_SETUP_REJECTION_REASON CStructuralValidator::MapChainFailure(const SMCChain &chain) const
  {
   if(chain.status == CHAIN_INCOMPLETE)
      return SETUP_REJECT_CHAIN_INCOMPLETE;
   if(chain.status == CHAIN_AMBIGUOUS)
      return SETUP_REJECT_CHAIN_AMBIGUOUS;

   string r = chain.failure_reason;
   if(StringFind(r, "structure") >= 0)
      return SETUP_REJECT_STRUCTURE;
   if(StringFind(r, "location") >= 0 || StringFind(r, "equilibrium") >= 0)
      return SETUP_REJECT_LOCATION;
   if(StringFind(r, "invalidation") >= 0)
      return SETUP_REJECT_INVALIDATION;
   if(StringFind(r, "FVG") >= 0)
      return SETUP_REJECT_CHAIN_INCOMPLETE;

   return SETUP_REJECT_NO_CHAIN;
  }

bool CStructuralValidator::ValidateHTF(bool forBuy, ENUM_SETUP_FAMILY family,
                                       bool &aligned, bool &conflict, string &reason)
  {
   aligned = false;
   conflict = false;
   reason = "";

   if(m_htfCtx == NULL || !m_htfCtx.candles.IsReady())
     {
      if(family == SETUP_FAMILY_CONTINUATION && m_requireContinuationHTFAlignment)
        {
         reason = "HTF trend data unavailable for continuation";
         return false;
        }
      return true;
     }

   ENUM_TREND_STATE t = m_htfCtx.trend.GetCurrentTrend();

   if(forBuy)
     {
      aligned = (t == TREND_BULL || t == TREND_BULL_STRONG);
      conflict = (t == TREND_BEAR || t == TREND_BEAR_STRONG);
     }
   else
     {
      aligned = (t == TREND_BEAR || t == TREND_BEAR_STRONG);
      conflict = (t == TREND_BULL || t == TREND_BULL_STRONG);
     }

   // Continuation requires higher-timeframe directional agreement.
   // Reversal deliberately does not: the CHoCH/MSS chain is the evidence
   // that a transition is underway, so an opposing prior HTF trend is
   // context, not an automatic veto.
   if(family == SETUP_FAMILY_CONTINUATION && m_requireContinuationHTFAlignment && !aligned)
     {
      reason = conflict ? "continuation conflicts with HTF trend"
                        : "continuation lacks aligned HTF trend";
      return false;
     }

   return true;
  }

bool CStructuralValidator::Validate(bool forBuy, StructuralValidationResult &out)
  {
   ZeroMemory(out);
   out.valid = false;
   out.direction = forBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   out.rejection_reason = SETUP_REJECT_NO_CHAIN;

   SMCChain chain = m_builder.Build(forBuy);
   out.chain = chain;
   out.family = chain.family;
   out.entry_fvg = chain.fvg;
   out.invalidation_price = chain.invalidation_price;
   out.structural_quality = chain.quality;
   out.validated_time = TimeCurrent();

   if(chain.status != CHAIN_VALID)
     {
      out.rejection_reason = MapChainFailure(chain);
      out.reason = chain.failure_reason;
      return false;
     }

   string htfReason;
   if(!ValidateHTF(forBuy, chain.family, out.htf_aligned, out.htf_conflict, htfReason))
     {
      out.rejection_reason = SETUP_REJECT_STRUCTURE;
      out.reason = htfReason;
      return false;
     }

   // Structural quality is only an attribute of an already valid chain.
   // It can never promote CHAIN_INVALID/INCOMPLETE to valid.
   out.valid = true;
   out.rejection_reason = SETUP_REJECT_NONE;
   out.reason = StringFormat("%s SMC chain validated; quality %.1f; family=%s%s",
                            forBuy ? "BUY" : "SELL",
                            out.structural_quality,
                            chain.family == SETUP_FAMILY_REVERSAL ? "REVERSAL" : "CONTINUATION",
                            out.htf_conflict ? " (HTF conflict tolerated because setup is a reversal)" : "");
   return true;
  }

#endif
//+------------------------------------------------------------------+
