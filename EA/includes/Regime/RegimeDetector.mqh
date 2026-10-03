//+------------------------------------------------------------------+
//|                                       Regime/RegimeDetector.mqh   |
//+------------------------------------------------------------------+
#ifndef REGIMEDETECTOR_MQH
#define REGIMEDETECTOR_MQH

#include "../Core/Config.mqh"
#include "../Analysis/TrendEngine.mqh"
#include "../Analysis/VolatilityRegime.mqh"
#include "../SmartMoney/MarketPhase.mqh"

// v2.17 hardening. Regime is now an action-relevant market-state gate,
// not merely a CSV diagnostic. The detector remains deliberately
// conservative: UNKNOWN/TRANSITION never grants a trade by itself.
//
// v2.12 addition. Everything downstream in the multi-strategy design
// (Momentum/Breakout vs Mean Reversion vs Key-Level Price Action) is
// supposed to branch off "what kind of market is this", so this is
// built first, and deliberately reuses the three reads that already
// exist rather than inventing a fourth "is this trending" heuristic:
//   - CTrendEngine.GetCurrentTrend()   -> BOS-backed swing structure
//   - CVolatilityRegime.Classify()     -> ATR-percentile expansion/compression
//   - CMarketPhase.Detect()            -> range-compression + sweep/displacement read
//
// THE HONEST LIMIT: CMarketPhase's own header already flags itself as
// "the least rigorously-defined concept" in this codebase — a narrative
// heuristic, not a proven detector. This class inherits that limit
// rather than hiding it: REGIME_TRANSITION is deliberately the catch-all
// for everything that isn't a clean TRENDING or RANGING read, instead of
// forcing every bar into one of two buckets a weak signal can't actually
// support.
//
// DIAGNOSTIC ONLY. Nothing reads Classify()'s return value except
// CSV logging (see SetupReasons.regime in Core/Config.mqh) and, later,
// the strategy-selection engine this doc argues for — which does not
// exist yet. No entry filter, confidence calculation, or order path
// consults this today.
class CRegimeDetector
  {
private:
   CTrendEngine*        m_trend;
   CVolatilityRegime*   m_volRegime;
   CMarketPhase*        m_phase;

   bool TrendMatches(bool forBuy, ENUM_TREND_STATE trend) const
     {
      return forBuy ? (trend == TREND_BULL_STRONG || trend == TREND_BULL)
                    : (trend == TREND_BEAR_STRONG || trend == TREND_BEAR);
     }

public:
                        CRegimeDetector() : m_trend(NULL), m_volRegime(NULL), m_phase(NULL) {}
   void                 Init(CTrendEngine* trend, CVolatilityRegime* volRegime, CMarketPhase* phase)
     {
      m_trend = trend;
      m_volRegime = volRegime;
      m_phase = phase;
     }
   ENUM_MARKET_REGIME   Classify();

   // v2.17: explicit action policy. Classification and permission are
   // separate so the diagnostic read cannot accidentally become a trade
   // merely by being non-UNDEFINED.
   bool                 AllowsSetup(bool forBuy, ENUM_SETUP_FAMILY family, string &reason);
  };
//+------------------------------------------------------------------+
ENUM_MARKET_REGIME CRegimeDetector::Classify()
  {
   if(m_trend == NULL || m_volRegime == NULL || m_phase == NULL)
      return REGIME_UNDEFINED;

   ENUM_TREND_STATE  trend = m_trend.GetCurrentTrend();
   ENUM_VOL_REGIME   vol   = m_volRegime.Classify(1);
   ENUM_MARKET_PHASE phase = m_phase.Detect();

   // Fail closed on an unverifiable volatility read, same convention as
   // every other percentile-based gate in this codebase (see
   // CVolatilityRegime::Classify's own comment).
   if(vol == VOL_REGIME_UNDEFINED)
      return REGIME_UNDEFINED;

   bool strongTrend = (trend == TREND_BULL_STRONG || trend == TREND_BEAR_STRONG);
   bool weakTrend    = (trend == TREND_BULL || trend == TREND_BEAR);

   // TRENDING: BOS-confirmed directional structure, and volatility is not
   // in a thin/choppy low-vol grind (LOW regime specifically flagged
   // elsewhere in this codebase as "thin, choppy, spread-risk-heavy" —
   // exactly the condition that makes a "trend" unreliable to trade).
   if(strongTrend && vol != VOL_REGIME_LOW)
      return REGIME_TRENDING;

   // RANGING: no directional structure at all, AND price is compressed
   // into a range with no recent sweep/displacement contaminating the
   // read (ACCUMULATION is CMarketPhase's own name for exactly this).
   if(trend == TREND_NEUTRAL && phase == PHASE_ACCUMULATION)
      return REGIME_RANGING;

   // Everything else is TRANSITION by construction: a weak/unconfirmed
   // trend, a strong trend fighting low volatility, a recent sweep or
   // displacement (MANIPULATION/DISTRIBUTION) that hasn't resolved into
   // either a clean trend or a clean range yet, or PHASE_UNDEFINED with
   // no compression to fall back on. This is not "figured it out and
   // it's ambiguous" — it's "the available reads don't support a
   // stronger claim", which is the same fail-closed posture the rest of
   // this class takes on VOL_REGIME_UNDEFINED above.
   return REGIME_TRANSITION;
  }
//+------------------------------------------------------------------+
// v2.17 action policy:
//   TRENDING -> continuation only, in the direction of the confirmed trend
//   RANGING  -> reversal only; seek internal liquidity mean-reversion
//   TRANSITION/UNDEFINED -> WAIT (no trade permission)
// This deliberately does not override StructuralValidator(). Structure
// must already be valid before this gate is consulted.
bool CRegimeDetector::AllowsSetup(bool forBuy, ENUM_SETUP_FAMILY family, string &reason)
  {
   reason = "";
   if(m_trend == NULL || m_volRegime == NULL || m_phase == NULL)
     {
      reason = "regime dependencies unavailable";
      return false;
     }

   ENUM_MARKET_REGIME regime = Classify();
   ENUM_TREND_STATE trend = m_trend.GetCurrentTrend();
   ENUM_VOL_REGIME vol = m_volRegime.Classify(1);
   ENUM_MARKET_PHASE phase = m_phase.Detect();

   if(regime == REGIME_UNDEFINED)
     {
      reason = "regime undefined / insufficient confirmed data";
      return false;
     }
   if(vol == VOL_REGIME_LOW)
     {
      reason = "low-volatility regime is not granted trade permission";
      return false;
     }

   if(regime == REGIME_TRENDING)
     {
      if(family != SETUP_FAMILY_CONTINUATION)
        {
         reason = "strong directional trend: reversal family blocked";
         return false;
        }
      if(!TrendMatches(forBuy, trend))
        {
         reason = "continuation direction conflicts with confirmed trend";
         return false;
        }
      reason = "trend-compatible continuation";
      return true;
     }

   if(regime == REGIME_RANGING)
     {
      if(family != SETUP_FAMILY_REVERSAL)
        {
         reason = "compressed range: continuation family blocked";
         return false;
        }
      if(phase != PHASE_ACCUMULATION)
        {
         reason = "range read is not a clean accumulation phase";
         return false;
        }
      reason = "range-compatible reversal";
      return true;
     }

   reason = "market transition: wait for regime resolution";
   return false;
  }
#endif
//+------------------------------------------------------------------+
