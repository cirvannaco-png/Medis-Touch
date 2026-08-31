//+------------------------------------------------------------------+
//|                                        includes/RegimeDetector.mqh |
//|  v2.12 public facade for the market-regime classifier              |
//+------------------------------------------------------------------+
// Combines the existing trend, volatility-regime, and market-phase reads
// into one TRENDING/RANGING/TRANSITION/UNDEFINED classification.
// Diagnostic only — see Regime/RegimeDetector.mqh for the full rationale
// and Core/Config.mqh for ENUM_MARKET_REGIME.
//
// Wiring reference (see Analysis/Scoring.mqh):
//   m_regimeDetector.Init(&m_trendCtx.trend, &m_volRegime, &m_phase);
#ifndef REGIMEDETECTOR_FACADE_MQH
#define REGIMEDETECTOR_FACADE_MQH

#include "Regime/RegimeDetector.mqh"   // CRegimeDetector + ENUM_MARKET_REGIME

#endif
//+------------------------------------------------------------------+
