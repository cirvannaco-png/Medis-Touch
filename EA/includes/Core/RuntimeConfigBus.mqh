//+------------------------------------------------------------------+
//| Core/RuntimeConfigBus.mqh                                        |
//| Dependency-inversion seam between ConfigSync and the EA engine.   |
//+------------------------------------------------------------------+
#ifndef RUNTIMECONFIGBUS_MQH
#define RUNTIMECONFIGBUS_MQH

#include "RuntimeParameters.mqh"

interface IRuntimeConfigConsumer
  {
   void ApplyRuntimeParameters(const RuntimeParameters &parameters);
  };

IRuntimeConfigConsumer *g_runtimeConfigConsumer = NULL;

void BindRuntimeConfigConsumer(IRuntimeConfigConsumer *consumer)
  {
   g_runtimeConfigConsumer = consumer;
  }

IRuntimeConfigConsumer *GetRuntimeConfigConsumer()
  {
   return g_runtimeConfigConsumer;
  }

#endif // RUNTIMECONFIGBUS_MQH
//+------------------------------------------------------------------+
