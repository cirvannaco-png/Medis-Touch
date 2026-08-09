//+------------------------------------------------------------------+
//|                                     includes/VolatilityRegime.mqh |
//|  v2.8 public facade for the ATR-percentile volatility regime gate  |
//+------------------------------------------------------------------+
// Answers "is the current bar's ATR unusually low/high against its own
// recent history", percentile-based so it self-calibrates per symbol and
// timeframe instead of needing a magic multiple. Distinct from
// CMarketPhase, which only asks whether price is compressed into a range.
//
// Wiring reference (see MedisTouch_v2.8.mq5 / Analysis/Scoring.mqh):
//   g_scoring.ConfigureVolatilityRegime(InpBlockLowVolRegime, InpVolRegimeLookback,
//                                       InpVolRegimeLowPct, InpVolRegimeHighPct);
#ifndef VOLATILITYREGIME_FACADE_MQH
#define VOLATILITYREGIME_FACADE_MQH

#include "Analysis/VolatilityRegime.mqh"   // CVolatilityRegime + ENUM_VOL_REGIME

#endif
//+------------------------------------------------------------------+
