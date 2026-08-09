//+------------------------------------------------------------------+
//|                                         SmartMoney/MarketPhase.mqh |
//+------------------------------------------------------------------+
#ifndef MARKETPHASE_MQH
#define MARKETPHASE_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../SmartMoney/Liquidity.mqh"

// HONEST CAVEAT: this is the least rigorously-defined concept in the
// v2.1 upgrade — "accumulation / manipulation / distribution" is a
// narrative description, not something with a single agreed-upon
// technical definition the way BOS or an FVG is. What follows is a
// reasonable, ATR-relative heuristic (range compression -> recent sweep
// -> recent displacement), not a claim that it detects "institutional
// intent". Treat it as a supplementary filter, not a ground truth signal
// — that's why it ships as an optional gate (default OFF) rather than a
// hard requirement like the Inducement engine's sweep+BOS check.
class CMarketPhase
  {
private:
   CCandleData*      m_candles;
   CLiquidity*       m_liquidity;
   int               m_rangeLookback;
   double            m_compressionATRMult;
   int               m_sweepRecencyBars;
   double            m_displacementATRMult;

   bool              IsDisplacementBar(int idx);

public:
                     CMarketPhase();
   void              Init(CCandleData* candles, CLiquidity* liquidity, int rangeLookback = 20,
                          double compressionATRMult = 2.5, int sweepRecencyBars = 6,
                          double displacementATRMult = 1.2);
   ENUM_MARKET_PHASE Detect();
  };
//+------------------------------------------------------------------+
CMarketPhase::CMarketPhase() : m_candles(NULL), m_liquidity(NULL), m_rangeLookback(20),
                                m_compressionATRMult(2.5), m_sweepRecencyBars(6), m_displacementATRMult(1.2) {}
//+------------------------------------------------------------------+
void CMarketPhase::Init(CCandleData* candles, CLiquidity* liquidity, int rangeLookback,
                        double compressionATRMult, int sweepRecencyBars, double displacementATRMult)
  {
   m_candles = candles;
   m_liquidity = liquidity;
   m_rangeLookback = MathMax(5, rangeLookback);
   m_compressionATRMult = compressionATRMult;
   m_sweepRecencyBars = MathMax(1, sweepRecencyBars);
   m_displacementATRMult = displacementATRMult;
  }
//+------------------------------------------------------------------+
bool CMarketPhase::IsDisplacementBar(int idx)
  {
   if(m_candles == NULL) return false;
   CandleData cd = m_candles.GetCandle(idx);
   double atr = m_candles.GetATR(idx);
   if(atr <= 0) return false;
   double range = cd.high - cd.low;
   if(range <= 0) return false;
   double body = MathAbs(cd.close - cd.open);
   return (range / atr >= m_displacementATRMult) && (body / range >= 0.5);
  }
//+------------------------------------------------------------------+
ENUM_MARKET_PHASE CMarketPhase::Detect()
  {
   if(m_candles == NULL || m_candles.Total() < m_rangeLookback + 2) return PHASE_UNDEFINED;
   double atr = m_candles.GetATR(0);
   if(atr <= 0) return PHASE_UNDEFINED;

   double hh = -DBL_MAX, ll = DBL_MAX;
   for(int i = 0; i < m_rangeLookback; i++)
     {
      CandleData cd = m_candles.GetCandle(i);
      if(cd.high > hh) hh = cd.high;
      if(cd.low  < ll) ll = cd.low;
     }
   bool compressed = ((hh - ll) / atr) <= m_compressionATRMult;

   bool recentSweep = false;
   if(m_liquidity != NULL && m_liquidity.EventCount() > 0)
     {
      LiquidityEvent ev = m_liquidity.GetEvent(0);
      if(ev.bar_index <= m_sweepRecencyBars) recentSweep = true;
     }

   bool recentDisplacement = false;
   for(int i = 0; i < MathMin(3, m_sweepRecencyBars); i++)
      if(IsDisplacementBar(i)) { recentDisplacement = true; break; }

   if(recentSweep && recentDisplacement) return PHASE_DISTRIBUTION;
   if(recentSweep) return PHASE_MANIPULATION;
   if(compressed) return PHASE_ACCUMULATION;
   return PHASE_UNDEFINED;
  }
#endif
//+------------------------------------------------------------------+
