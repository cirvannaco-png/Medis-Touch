//+------------------------------------------------------------------+
//|                          Strategies/StrategySetupRouter.mqh       |
//| Strategy selection -> strategy-specific setup seam               |
//+------------------------------------------------------------------+
#ifndef STRATEGYSETUPROUTER_MQH
#define STRATEGYSETUPROUTER_MQH

#include "../Core/Config.mqh"

// This router deliberately refuses to execute a diagnostic-only strategy.
// A selector saying "MEAN_REVERSION" is not enough to trade it: that
// strategy needs its own entry, invalidation and target construction.
// Silently reusing the SMC/FVG setup for a different selected strategy
// would corrupt attribution and make calibration meaningless.
class CStrategySetupRouter
  {
public:
   bool Route(ENUM_SELECTED_STRATEGY selected,
              const TradeSetup &smcSetup,
              TradeSetup &out,
              string &reason)
     {
      ZeroMemory(out);
      reason = "";

      if(selected == STRATEGY_SMC)
        {
         out = smcSetup;
         reason = "SMC strategy setup";
         return out.active;
        }

      if(selected == STRATEGY_MOMENTUM_BREAKOUT)
        {
         reason = "Momentum/Breakout selected, but its production setup adapter is not implemented; refusing to substitute the SMC/FVG setup";
         return false;
        }
      if(selected == STRATEGY_MEAN_REVERSION)
        {
         reason = "Mean Reversion selected, but its production setup adapter is not implemented; refusing to substitute the SMC/FVG setup";
         return false;
        }
      if(selected == STRATEGY_KEY_LEVEL)
        {
         reason = "Key-Level selected, but its production setup adapter is not implemented; refusing to substitute the SMC/FVG setup";
         return false;
        }

      reason = "No executable strategy selected";
      return false;
     }
  };

#endif
//+------------------------------------------------------------------+
