//+------------------------------------------------------------------+
//|                                      includes/StrategySelector.mqh |
//|  v2.15 public facade for the strategy selection diagnostic layer  |
//+------------------------------------------------------------------+
// The fourth and last layer added in this batch (v2.12-v2.15). Compares
// the already-computed diagnostic scores from the three strategy
// modules against the live SMC engine's own confidence, per regime, and
// records which one WOULD have been selected. Never sums scores — see
// Strategies/StrategySelector.mqh's header for why that distinction is
// the entire point of this class. Diagnostic only — see
// Core/Config.mqh for ENUM_SELECTED_STRATEGY.
//
// Wiring reference (see Analysis/Scoring.mqh): no Init() needed — this
// class has no engine dependencies, only Configure(). Called from
// PopulateStrategyDiagnostics() after all four reads are populated.
#ifndef STRATEGYSELECTOR_FACADE_MQH
#define STRATEGYSELECTOR_FACADE_MQH

#include "Strategies/StrategySelector.mqh"   // CStrategySelector + ENUM_SELECTED_STRATEGY

#endif
//+------------------------------------------------------------------+
