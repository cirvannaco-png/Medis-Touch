//+------------------------------------------------------------------+
//|                                       includes/MomentumBreakout.mqh |
//|  v2.12 public facade for the Momentum/Breakout diagnostic strategy  |
//+------------------------------------------------------------------+
// Strategy module #1 of the multi-strategy architecture. Classifies the
// most recent BOS in the setup's direction into Expansion/Liquidity/
// Failed/Exhaustion and produces an independent momentum score.
// Diagnostic only — see Strategies/MomentumBreakout.mqh for the full
// rationale and Core/Config.mqh for ENUM_BREAKOUT_CLASS.
//
// Wiring reference (see Analysis/Scoring.mqh):
//   m_momentumEngine.Init(&m_bosCtx.candles, &m_bosCtx.bos, &m_liqCtx.liquidity, &m_volRegime);
#ifndef MOMENTUMBREAKOUT_FACADE_MQH
#define MOMENTUMBREAKOUT_FACADE_MQH

#include "Strategies/MomentumBreakout.mqh"   // CMomentumBreakoutEngine + ENUM_BREAKOUT_CLASS

#endif
//+------------------------------------------------------------------+
