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

   LiquidityPool     m_pools[];   // FINAL/current-state pools (all data known) — for display/GetPool() only
   int               m_poolCount;
   LiquidityEvent    m_events[];
   int               m_eventCount;

   void              BuildInternalPools();  // final-state pools, for GetPool()/dashboard display
   void              BuildExternalPools();  // final-state "yesterday" pool, for GetPool()/dashboard display
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
// FINAL-STATE pool list, built from the complete, current swing data —
// this is intentionally "everything we know today" and is only used for
// GetPool()/PoolCount() (dashboard, current-analysis display). It is NOT
// used for historical sweep detection — see DetectSweeps() below, which
// rebuilds pools chronologically bar-by-bar to avoid lookahead.
void CLiquidity::BuildInternalPools()
  {
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
            pool.confirmed_at_shift = 0;
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
            pool.confirmed_at_shift = 0;
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
   if(m_candles == NULL) return;
   string sym = m_candles.Symbol();
   double dayHigh = iHigh(sym, PERIOD_D1, 1);
   double dayLow  = iLow(sym, PERIOD_D1, 1);
   if(dayHigh > 0)
     {
      LiquidityPool pool;
      pool.price_top = dayHigh;
      pool.price_bottom = dayHigh;
      pool.type = LIQ_BUY_SIDE;
      pool.touches = 1;
      pool.external = true;
      pool.confirmed_at_shift = 0;
      int n = m_poolCount++;
      ArrayResize(m_pools, m_poolCount);
      m_pools[n] = pool;
     }
   if(dayLow > 0)
     {
      LiquidityPool pool;
      pool.price_top = dayLow;
      pool.price_bottom = dayLow;
      pool.type = LIQ_SELL_SIDE;
      pool.touches = 1;
      pool.external = true;
      pool.confirmed_at_shift = 0;
      int n = m_poolCount++;
      ArrayResize(m_pools, m_poolCount);
      m_pools[n] = pool;
     }
  }
//+------------------------------------------------------------------+
// FIX (audit #11 — lookahead bias): the previous version built pools
// from the CURRENT, fully up-to-date swing list — "swing A + swing B
// exist" using every swing ever detected, including ones that formed
// AFTER a given historical bar — and then scanned ALL of history for
// sweeps of those pools. A candle from months ago could get flagged as
// "sweeping" a pool that, at the time, didn't exist yet (its second
// component swing hadn't happened). Correct chronology is: swing A +
// swing B both confirmed -> pool exists -> THEN a later bar can sweep
// it. This function enforces exactly that using LiquidityPool's new
// confirmed_at_shift field: a candidate sweep at `bar` is only tested
// against an internal pool if `bar <= pool.confirmed_at_shift` (the pool
// must already have existed as of that bar).
//
// External (daily high/low) pools have the SAME problem in a different
// form: a single static "yesterday's high/low" computed from TODAY's
// perspective was being used to test sweep candles from arbitrary points
// in history — but "yesterday" is a different level every day. Fixed by
// computing each candle's own actual prior trading day's D1 high/low at
// scan time instead of using one fixed pair of levels for all of history.
void CLiquidity::DetectSweeps()
  {
   m_eventCount = 0;
   if(m_candles == NULL || m_swings == NULL) return;
   ArrayFree(m_events);
   int total = m_candles.Total();
   int strength = m_swings.Strength();
   string sym = m_candles.Symbol();

   // --- Internal pools: rebuild WITH confirmation-shift tagging ---
   LiquidityPool internalPools[];
   int internalCount = 0;
   int hc = m_swings.HighCount();
   for(int i = 0; i < hc - 1; i++)
     {
      SwingPoint a = m_swings.GetHigh(i);
      double atrA = m_candles.GetATR(a.bar_index);
      double band = m_internalThresholdATR * atrA;
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
            // Pool only valid once BOTH swings are confirmed — that's the
            // LATER of the two confirmations, i.e. the smaller (more
            // recent) confirm_shift value.
            pool.confirmed_at_shift = MathMin(a.bar_index - strength, b.bar_index - strength);
            int n = internalCount++;
            ArrayResize(internalPools, internalCount);
            internalPools[n] = pool;
           }
        }
     }
   int lc = m_swings.LowCount();
   for(int i = 0; i < lc - 1; i++)
     {
      SwingPoint a = m_swings.GetLow(i);
      double atrA = m_candles.GetATR(a.bar_index);
      double band = m_internalThresholdATR * atrA;
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
            pool.confirmed_at_shift = MathMin(a.bar_index - strength, b.bar_index - strength);
            int n = internalCount++;
            ArrayResize(internalPools, internalCount);
            internalPools[n] = pool;
           }
        }
     }

   for(int i = 0; i < internalCount; i++)
     {
      for(int bar = 1; bar < total - 2; bar++)
        {
         if(bar > internalPools[i].confirmed_at_shift) continue; // FIX #11: pool didn't exist yet at this bar
         CandleData cd = m_candles.GetCandle(bar);
         double atr = m_candles.GetATR(bar);
         if(atr <= 0) continue;

         if(internalPools[i].type == LIQ_BUY_SIDE)
           {
            if(cd.high > internalPools[i].price_top && cd.close < internalPools[i].price_bottom)
              {
               double penetration = (cd.high - internalPools[i].price_top) / atr;
               LiquidityEvent ev;
               ev.time = cd.time;
               ev.price = internalPools[i].price_top;
               ev.type = LIQ_BUY_SIDE;
               ev.strength = MathMax(0.0, MathMin(penetration / 0.5, 1.0));
               ev.swept = true;
               ev.bar_index = bar;
               ev.external = false;
               int n = m_eventCount++;
               ArrayResize(m_events, m_eventCount);
               m_events[n] = ev;
               break;
              }
           }
         else
           {
            if(cd.low < internalPools[i].price_bottom && cd.close > internalPools[i].price_top)
              {
               double penetration = (internalPools[i].price_bottom - cd.low) / atr;
               LiquidityEvent ev;
               ev.time = cd.time;
               ev.price = internalPools[i].price_bottom;
               ev.type = LIQ_SELL_SIDE;
               ev.strength = MathMax(0.0, MathMin(penetration / 0.5, 1.0));
               ev.swept = true;
               ev.bar_index = bar;
               ev.external = false;
               int n = m_eventCount++;
               ArrayResize(m_events, m_eventCount);
               m_events[n] = ev;
               break;
              }
           }
        }
     }

   // --- External pools: each candle tested against ITS OWN prior trading
   // day's D1 high/low, not today's, via iBarShift — chronologically
   // correct by construction, no static level reused across all of history.
   int lastD1Shift = -1;
   double d1High = 0.0, d1Low = 0.0;
   for(int bar = 1; bar < total - 2; bar++)
     {
      CandleData cd = m_candles.GetCandle(bar);
      double atr = m_candles.GetATR(bar);
      if(atr <= 0) continue;

      int d1Shift = iBarShift(sym, PERIOD_D1, cd.time);
      if(d1Shift < 0) continue; // no daily data this far back
      if(d1Shift != lastD1Shift) // only refetch when we cross a day boundary — cheap
        {
         d1High = iHigh(sym, PERIOD_D1, d1Shift + 1); // the PRIOR day relative to this bar's own day
         d1Low  = iLow(sym, PERIOD_D1, d1Shift + 1);
         lastD1Shift = d1Shift;
        }

      if(d1High > 0 && cd.high > d1High && cd.close < d1High)
        {
         double penetration = (cd.high - d1High) / atr;
         LiquidityEvent ev;
         ev.time = cd.time;
         ev.price = d1High;
         ev.type = LIQ_BUY_SIDE;
         ev.strength = MathMax(0.0, MathMin(penetration / 0.5, 1.0));
         ev.swept = true;
         ev.bar_index = bar;
         ev.external = true;
         int n = m_eventCount++;
         ArrayResize(m_events, m_eventCount);
         m_events[n] = ev;
        }
      if(d1Low > 0 && cd.low < d1Low && cd.close > d1Low)
        {
         double penetration = (d1Low - cd.low) / atr;
         LiquidityEvent ev;
         ev.time = cd.time;
         ev.price = d1Low;
         ev.type = LIQ_SELL_SIDE;
         ev.strength = MathMax(0.0, MathMin(penetration / 0.5, 1.0));
         ev.swept = true;
         ev.bar_index = bar;
         ev.external = true;
         int n = m_eventCount++;
         ArrayResize(m_events, m_eventCount);
         m_events[n] = ev;
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
   BuildInternalPools();   // final-state, for display only
   BuildExternalPools();   // final-state, for display only
   DetectSweeps();         // chronologically rebuilt internally — see above
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
