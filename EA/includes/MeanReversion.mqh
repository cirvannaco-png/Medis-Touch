//+------------------------------------------------------------------+
//|                                        includes/MeanReversion.mqh |
//|  v2.13 public facade for the Mean Reversion diagnostic strategy   |
//+------------------------------------------------------------------+
// Strategy module #2 of the multi-strategy architecture. Scores a fade
// setup from value-area stretch or SR-zone rejection, sweep
// confirmation, controlled volatility, and a trend-conflict override.
// Diagnostic only — see Strategies/MeanReversion.mqh for the full
// rationale and Core/Config.mqh for ENUM_REVERSION_CLASS.
//
// Wiring reference (see Analysis/Scoring.mqh):
//   m_meanReversionEngine.Init(&m_srCtx.candles, &m_srCtx.sr, &m_srCtx.valueArea,
//                              &m_liqCtx.liquidity, &m_volRegimeSR, &m_bosCtx.bos);
#ifndef MEANREVERSION_FACADE_MQH
#define MEANREVERSION_FACADE_MQH

#include "Strategies/MeanReversion.mqh"   // CMeanReversionEngine + ENUM_REVERSION_CLASS

#endif
//+------------------------------------------------------------------+
