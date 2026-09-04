//+------------------------------------------------------------------+
//| Core/RuntimeParameters.mqh                                       |
//| Validated runtime configuration delivered by ConfigSync.          |
//+------------------------------------------------------------------+
#ifndef RUNTIMEPARAMETERS_MQH
#define RUNTIMEPARAMETERS_MQH

struct RuntimeParameters
  {
   int    ensemble_threshold;
   int    smc_threshold;
   int    momentum_threshold;
   int    breakout_threshold;
   int    mean_reversion_threshold;
   int    key_level_threshold;
   double fvg_proximity_atr;
   double contradiction_penalty;
   int    freshness_bars;

   void Defaults()
     {
      ensemble_threshold = 62;
      smc_threshold = 60;
      momentum_threshold = 60;
      breakout_threshold = 60;
      mean_reversion_threshold = 60;
      key_level_threshold = 60;
      fvg_proximity_atr = 0.20;
      contradiction_penalty = 0.10;
      freshness_bars = 12;
     }
  };

#endif // RUNTIMEPARAMETERS_MQH
//+------------------------------------------------------------------+
