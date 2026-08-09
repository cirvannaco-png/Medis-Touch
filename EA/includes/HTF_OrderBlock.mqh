//+------------------------------------------------------------------+
//|                                      includes/HTF_OrderBlock.mqh |
//|  v2.8 public facade for higher-timeframe Order Block confluence   |
//+------------------------------------------------------------------+
// COrderBlock is timeframe-agnostic by design: it reads whatever
// CCandleData it is Init()'d with. "HTF" is therefore a wiring decision,
// not a different algorithm - MedisTouch_v2.8.mq5 initialises it from
// g_htfObCtx (InpHtfObTF, e.g. H4/D1), deliberately a strictly higher
// timeframe than InpFVGTF/InpBOSTF. This header exists so that intent is
// visible at the include site rather than buried in OnInit().
//
// Wiring reference (see MedisTouch_v2.8.mq5 / Analysis/Scoring.mqh):
//   g_scoring.ConfigureHtfOrderBlock(g_htfObCtx, InpRequireHtfOB, InpOBDistATRMax);
// If InpHtfObTF is not higher than the entry timeframe the EA prints a
// warning at init - the filter still runs, but it is no longer HTF.
#ifndef HTF_ORDERBLOCK_MQH
#define HTF_ORDERBLOCK_MQH

#include "SmartMoney/OrderBlock.mqh"   // COrderBlock + OrderBlockZone / OB_FRESH|OB_TESTED|OB_MITIGATED

#endif
//+------------------------------------------------------------------+
