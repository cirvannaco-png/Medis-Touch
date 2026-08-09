//+------------------------------------------------------------------+
//|                                    includes/InducementEngine.mqh |
//|  v2.8 public facade for the inducement/manipulation decision path |
//+------------------------------------------------------------------+
// The engine itself lives in SmartMoney/ next to the concepts it reads
// (Inducement needs MarketPhase + PremiumDiscount to answer "was this a
// real stop run in the right part of the range"). This facade is the
// stable include path the EA and any external tooling should use, so the
// internal folder layout can change without touching call sites.
//
// Include guards in each underlying header make it safe to include this
// alongside the SmartMoney/* headers directly - nothing is redefined.
#ifndef INDUCEMENTENGINE_MQH
#define INDUCEMENTENGINE_MQH

#include "SmartMoney/Inducement.mqh"        // CInducement - impulse -> pullback -> sweep -> minor BOS
#include "SmartMoney/MarketPhase.mqh"       // CMarketPhase - accumulation / distribution context
#include "SmartMoney/PremiumDiscount.mqh"   // CPremiumDiscount - discount for buys, premium for sells

#endif
//+------------------------------------------------------------------+
