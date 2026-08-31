//+------------------------------------------------------------------+
//|                                     includes/KeyLevelReaction.mqh |
//|  v2.14 public facade for the Key-Level Reaction diagnostic strategy|
//+------------------------------------------------------------------+
// Strategy module #3 of the multi-strategy architecture. Finds the
// nearest key level (SR zone, order block, value area edge, or an
// external liquidity pool) and classifies price's reaction to it as
// structured categorical data instead of discretionary candle reading.
// Diagnostic only — see Strategies/KeyLevelReaction.mqh for the full
// rationale and Core/Config.mqh for ENUM_KEYLEVEL_SOURCE/ENUM_KEYLEVEL_REACTION.
//
// Wiring reference (see Analysis/Scoring.mqh):
//   m_keyLevelEngine.Init(&m_srCtx.candles, &m_srCtx.sr, &m_srCtx.valueArea,
//                         &m_liqCtx.liquidity, &m_srCtx.orderBlock);
#ifndef KEYLEVELREACTION_FACADE_MQH
#define KEYLEVELREACTION_FACADE_MQH

#include "Strategies/KeyLevelReaction.mqh"   // CKeyLevelEngine + ENUM_KEYLEVEL_SOURCE + ENUM_KEYLEVEL_REACTION

#endif
//+------------------------------------------------------------------+
