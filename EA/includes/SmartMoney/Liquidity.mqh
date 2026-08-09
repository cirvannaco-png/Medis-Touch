//+------------------------------------------------------------------+
//|                                            SmartMoney/Liquidity.mqh |
//+------------------------------------------------------------------+
#ifndef LIQUIDITY_MQH
#define LIQUIDITY_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../Structure/SwingDetector.mqh"

class CLiquidity
  {
private:
   CCandleData*      m_candles;
   CSwingDetector*   m_swings;
   double            m_internalThresholdATR;

   LiquidityPool     m_pools[];
   int               m_poolCount;
   LiquidityEvent    m_events[];
   int               m_eventCount;

   void              BuildInternalPools();
   void              BuildExternalPools();
   void              DetectSweeps();

public:
                     CLiquidity();
   void              Init(CCandleData* candles, CSwingDetector* swings, double internalThresholdATR = 0.2);
   void              Detect();
   int               PoolCount() const { return m_poolCount; }
   LiquidityPool     GetPool(int i) const;
   int               EventCount() const { return m_eventCount; }
   LiquidityEvent    GetEvent(int i) const; // 0 = most recent
   // Convenience wrappers for the Inducement/Scoring engines — "was the
   // most recent sweep of this kind within N bars?" without every caller
   // re-deriving it from raw events.
   bool              HasInternalSweep(int recencyBars, ENUM_LIQ_TYPE &outType, double &outStrength, int &outBarIndex);
   bool              HasExternalSweep(int recencyBars, ENUM_LIQ_TYPE &outType, double &outStrength, int &outBarIndex);
  };
//+------------------------------------------------------------------+
CLiquidity::CLiquidity() : m_candles(NULL), m_swings(NULL), m_internalThresholdATR(0.2), m_poolCount(0), m_eventCount(0) {}
void CLiquidity::Init(CCandleData* candles, CSwingDetector* swings, double internalThresholdATR)
  {
   m_candles = candles;
   m_swings = swings;
   m_internalThresholdATR = internalThresholdATR;
  }
//+------------------------------------------------------------------+
void CLiquidity::BuildInternalPools()
  {
   // Equal highs -> buy-side liquidity resting above price (sell target)
   int hc = m_swings.HighCount();
   for(int i = 0; i < hc - 1; i++)
     {
      SwingPoint a = m_swings.GetHigh(i);
      double atr = m_candles.GetATR(a.bar_index);
      double band = m_internalThresholdATR * atr;
      for(int j = i + 1; j < hc; j++)
        {
         SwingPoint b = m_swings.GetHigh(j);
         if(MathAbs(a.price - b.price) <= band)
           {
            LiquidityPool pool;
            pool.price_top = MathMax(a.price, b.price);
            pool.price_bottom = MathMin(a.price, b.price);
            pool.type = LIQ_BUY_SIDE;
            pool.touches = 2;
            pool.external = false;
            bool exists = false;
            for(int k = 0; k < m_poolCount; k++)
              {
               if(!m_pools[k].external && m_pools[k].type == pool.type &&
                  MathAbs(m_pools[k].price_top - pool.price_top) < band)
                 {
                  m_pools[k].touches++;
                  exists = true;
                  break;
                 }
              }
            if(!exists)
              {
               int n = m_poolCount++;
               ArrayResize(m_pools, m_poolCount);
               m_pools[n] = pool;
              }
           }
        }
     }
   // Equal lows -> sell-side liquidity resting below price (buy target)
   int lc = m_swings.LowCount();
   for(int i = 0; i < lc - 1; i++)
     {
      SwingPoint a = m_swings.GetLow(i);
      double atr = m_candles.GetATR(a.bar_index);
      double band = m_internalThresholdATR * atr;
      for(int j = i + 1; j < lc; j++)
        {
         SwingPoint b = m_swings.GetLow(j);
         if(MathAbs(a.price - b.price) <= band)
           {
            LiquidityPool pool;
            pool.price_top = MathMax(a.price, b.price);
            pool.price_bottom = MathMin(a.price, b.price);
            pool.type = LIQ_SELL_SIDE;
            pool.touches = 2;
            pool.external = false;
            bool exists = false;
            for(int k = 0; k < m_poolCount; k++)
              {
               if(!m_pools[k].external && m_pools[k].type == pool.type &&
                  MathAbs(m_pools[k].price_bottom - pool.price_bottom) < band)
                 {
                  m_pools[k].touches++;
                  exists = true;
                  break;
                 }
              }
            if(!exists)
              {
               int n = m_poolCount++;
               ArrayResize(m_pools, m_poolCount);
               m_pools[n] = pool;
              }
           }
        }
     }
  }
//+------------------------------------------------------------------+
void CLiquidity::BuildExternalPools()
  {
   // FIX: original called iHigh(m_candles.GetCandle(0).time, PERIOD_D1, 1)
   // — passing a datetime as the symbol argument. iHigh()'s signature is
   // (string symbol, ENUM_TIMEFRAMES period, int shift); that's a type
   // mismatch that fails to compile. Use the actual symbol.
   if(m_candles == NULL) return;
   string sym = m_candles.Symbol();
   double dayHigh = iHigh(sym, PERIOD_D1, 1);
   double dayLow  = iLow(sym, PERIOD_D1, 1);
   if(dayHigh > 0)
     {
      LiquidityPool pool;
      pool.price_top = dayHigh;
      pool.price_bottom = dayHigh;
      pool.type = LIQ_BUY_SIDE;  // resting above price -> sell-side target for buyers to sweep
      pool.touches = 1;
      pool.external = true;
      int n = m_poolCount++;
      ArrayResize(m_pools, m_poolCount);
      m_pools[n] = pool;
     }
   if(dayLow > 0)
     {
      LiquidityPool pool;
      pool.price_top = dayLow;
      pool.price_bottom = dayLow;
      pool.type = LIQ_SELL_SIDE; // resting below price -> buy-side target for sellers to sweep
      pool.touches = 1;
      pool.external = true;
      int n = m_poolCount++;
      ArrayResize(m_pools, m_poolCount);
      m_pools[n] = pool;
     }
  }
//+------------------------------------------------------------------+
void CLiquidity::DetectSweeps()
  {
   m_eventCount = 0;
   if(m_candles == NULL) return;
   ArrayFree(m_events);
   int total = m_candles.Total();

   for(int i = 0; i < m_poolCount; i++)
     {
      for(int bar = 1; bar < total - 2; bar++)
        {
         CandleData cd = m_candles.GetCandle(bar);
         double atr = m_candles.GetATR(bar);
         if(atr <= 0) continue;

         if(m_pools[i].type == LIQ_BUY_SIDE) // wick above, close back below -> sweep
           {
            if(cd.high > m_pools[i].price_top && cd.close < m_pools[i].price_bottom)
              {
               // FIX: strength was a hardcoded 0.8 for every event. Real
               // strength = how far the wick penetrated beyond the pool,
               // relative to ATR (deeper sweep = stronger reversal signal).
               double penetration = (cd.high - m_pools[i].price_top) / atr;
               LiquidityEvent ev;
               ev.time = cd.time;
               ev.price = m_pools[i].price_top;
               ev.type = LIQ_BUY_SIDE;
               ev.strength = MathMax(0.0, MathMin(penetration / 0.5, 1.0));
               ev.swept = true;
               ev.bar_index = bar;
               ev.external = m_pools[i].external;
               int n = m_eventCount++;
               ArrayResize(m_events, m_eventCount);
               m_events[n] = ev;
               break;
              }
           }
         else // sell-side: wick below, close back above -> sweep
           {
            if(cd.low < m_pools[i].price_bottom && cd.close > m_pools[i].price_top)
              {
               double penetration = (m_pools[i].price_bottom - cd.low) / atr;
               LiquidityEvent ev;
               ev.time = cd.time;
               ev.price = m_pools[i].price_bottom;
               ev.type = LIQ_SELL_SIDE;
               ev.strength = MathMax(0.0, MathMin(penetration / 0.5, 1.0));
               ev.swept = true;
               ev.bar_index = bar;
               ev.external = m_pools[i].external;
               int n = m_eventCount++;
               ArrayResize(m_events, m_eventCount);
               m_events[n] = ev;
               break;
              }
           }
        }
     }
   // Order events most-recent-first for downstream consumers (Scoring
   // wants "did a sweep just happen", not "did one ever happen").
   for(int a = 0; a < m_eventCount - 1; a++)
      for(int b = a + 1; b < m_eventCount; b++)
         if(m_events[b].bar_index < m_events[a].bar_index)
           {
            LiquidityEvent t = m_events[a];
            m_events[a] = m_events[b];
            m_events[b] = t;
           }
  }
//+------------------------------------------------------------------+
void CLiquidity::Detect()
  {
   m_poolCount = 0;
   if(m_candles == NULL || m_swings == NULL) return;
   ArrayFree(m_pools);
   BuildInternalPools();
   BuildExternalPools();
   DetectSweeps();
  }
LiquidityPool CLiquidity::GetPool(int i) const { if(i<0||i>=m_poolCount) { LiquidityPool e; ZeroMemory(e); return e; } return m_pools[i]; }
LiquidityEvent CLiquidity::GetEvent(int i) const { if(i<0||i>=m_eventCount) { LiquidityEvent e; ZeroMemory(e); return e; } return m_events[i]; }
//+------------------------------------------------------------------+
bool CLiquidity::HasInternalSweep(int recencyBars, ENUM_LIQ_TYPE &outType, double &outStrength, int &outBarIndex)
  {
   for(int i = 0; i < m_eventCount; i++)
     {
      if(m_events[i].external) continue;
      if(m_events[i].bar_index > recencyBars) continue;
      outType = m_events[i].type;
      outStrength = m_events[i].strength;
      outBarIndex = m_events[i].bar_index;
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
bool CLiquidity::HasExternalSweep(int recencyBars, ENUM_LIQ_TYPE &outType, double &outStrength, int &outBarIndex)
  {
   for(int i = 0; i < m_eventCount; i++)
     {
      if(!m_events[i].external) continue;
      if(m_events[i].bar_index > recencyBars) continue;
      outType = m_events[i].type;
      outStrength = m_events[i].strength;
      outBarIndex = m_events[i].bar_index;
      return true;
     }
   return false;
  }
#endif
//+------------------------------------------------------------------+
