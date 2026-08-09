//+------------------------------------------------------------------+
//|                                       Decision/TradeDecision.mqh |
//|  Shared record types for the analysis -> decision -> action seam. |
//+------------------------------------------------------------------+
// This header holds ONLY data types (no engines), because three layers
// need them and none of them should depend on each other:
//   * CDecisionEngine  produces a TradeDecisionRecord from a TradeSetup
//   * COrderManager / CSignalPublisher consume it
//   * CDecisionStore   persists it (and ExecutionRecord) so a restarted
//     terminal can be reconciled against broker-side truth by
//     CRecoveryEngine.
#ifndef TRADEDECISION_MQH
#define TRADEDECISION_MQH

#include "../Core/Config.mqh"

// What the router decided to DO with a validated setup. Execution and
// signalling are independent switches, so the combined case is its own
// value rather than a bitmask - every consumer compares against explicit
// values and a bitmask would silently pass `& POLICY_EXECUTE_ONLY` tests
// for the combined case in some places but not others.
enum ENUM_TRADE_POLICY
  {
   POLICY_IGNORE = 0,            // do nothing (below thresholds, or both switches off)
   POLICY_SIGNAL_ONLY,           // publish to subscribers, place no order
   POLICY_EXECUTE_ONLY,          // place the order, publish nothing
   POLICY_EXECUTE_AND_SIGNAL     // both
  };

string TradePolicyToString(ENUM_TRADE_POLICY p)
  {
   switch(p)
     {
      case POLICY_SIGNAL_ONLY:        return "SIGNAL_ONLY";
      case POLICY_EXECUTE_ONLY:       return "EXECUTE_ONLY";
      case POLICY_EXECUTE_AND_SIGNAL: return "EXECUTE_AND_SIGNAL";
      default:                        return "IGNORE";
     }
  }

// One routed decision. `setup` is copied by value on purpose: the setup
// object in the analysis layer is regenerated every bar, while a decision
// must stay immutable for the whole life of the trade it created (Recovery
// re-reads it after a restart, possibly days later).
struct TradeDecisionRecord
  {
   long              decision_id;     // matching key; also written into the order comment as "MT#<id>"
   string            symbol;
   TradeSetup        setup;           // the exact setup that was approved
   ENUM_TRADE_POLICY action;
   bool              reduce_risk;     // confidence below InpFullRiskConfidence -> size down
   bool              valid;           // false = the router rejected it; nothing downstream should act
   double            confidence;      // copy of setup.confidence at decision time (setup may be re-scored later)
   double            spread_points;   // spread observed when the decision was taken, for post-hoc analysis
   datetime          decided_time;
   string            reason;          // human-readable why, mirrored into the CSV store
  };

// Written when (and only when) an order actually reached the broker, so
// Recovery can tell "decision existed" from "decision was submitted at
// this volume on this ticket".
struct ExecutionRecord
  {
   long              decision_id;
   double            volume;
   ulong             ticket;
   datetime          submitted_time;
  };

#endif
//+------------------------------------------------------------------+
