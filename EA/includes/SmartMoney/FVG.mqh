//+------------------------------------------------------------------+
//|                                                SmartMoney/FVG.mqh |
//+------------------------------------------------------------------+
#ifndef FVG_MQH
#define FVG_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"

class CFVG
  {
private:
   CCandleData*      m_candles;
   FVGZone           m_zones[];
   int               m_zoneCount;

   double            m_minSizeATR;   // minimum gap size as fraction of ATR

   void              UpdateState(FVGZone &zone);

public:
                     CFVG();
   void              Init(CCandleData* candleData, double minSizeATR = 0.1);
   void              Detect();
   int               Count() const { return m_zoneCount; }
   FVGZone           GetZone(int i) const; // 0 = most recent
   void              UpdateAllStates();
  };
//+------------------------------------------------------------------+
CFVG::CFVG() : m_candles(NULL), m_zoneCount(0), m_minSizeATR(0.1) {}
void CFVG::Init(CCandleData* candleData, double minSizeATR)
  {
   m_candles = candleData;
   m_minSizeATR = minSizeATR;
  }
//+------------------------------------------------------------------+
void CFVG::Detect()
  {
   m_zoneCount = 0;
   if(m_candles == NULL) return;
   ArrayFree(m_zones);
   int total = m_candles.Total();
   if(total < 3) return;

   // Series-indexed: shift 0 = now. As i runs 2 -> total-1, the 3-bar
   // window {i, i-1, i-2} slides from the most recent triplet toward the
   // oldest. Within a triplet: cd2 = GetCandle(i) is the OLDEST of the
   // three (largest shift); cd0 = GetCandle(i-2) is the NEWEST of the
   // three (smallest shift). (The original comments had this backwards —
   // labels only, the gap-direction math itself was already correct.)
   for(int i = 2; i < total; i++)
     {
      CandleData cd0 = m_candles.GetCandle(i - 2); // newest of the triplet
      CandleData cd1 = m_candles.GetCandle(i - 1); // middle
      CandleData cd2 = m_candles.GetCandle(i);     // oldest of the triplet
      double atr = cd1.atr;
      if(atr <= 0) continue;

      // Bullish FVG: low of the newest candle > high of the oldest candle
      if(cd0.low > cd2.high)
        {
         double gap = cd0.low - cd2.high;
         if(gap >= m_minSizeATR * atr)
           {
            FVGZone zone;
            zone.time = cd1.time;
            zone.top = cd0.low;
            zone.bottom = cd2.high;
            zone.dir = FVG_BULL;
            zone.state = FVG_FRESH;
            zone.width = gap / atr;
            zone.bar_index = i - 1;
            int n = m_zoneCount++;
            ArrayResize(m_zones, m_zoneCount);
            m_zones[n] = zone;
           }
        }
      // Bearish FVG: high of the newest candle < low of the oldest candle
      else if(cd0.high < cd2.low)
        {
         double gap = cd2.low - cd0.high;
         if(gap >= m_minSizeATR * atr)
           {
            FVGZone zone;
            zone.time = cd1.time;
            zone.top = cd2.low;
            zone.bottom = cd0.high;
            zone.dir = FVG_BEAR;
            zone.state = FVG_FRESH;
            zone.width = gap / atr;
            zone.bar_index = i - 1;
            int n = m_zoneCount++;
            ArrayResize(m_zones, m_zoneCount);
            m_zones[n] = zone;
           }
        }
     }
   // NOTE: no reversal needed — the loop runs from the most recent
   // triplet to the oldest, so m_zones[0] is already the most recent
   // zone. (Original code reversed unconditionally here too, which
   // inverted GetZone(0) to the oldest FVG in the whole history window —
   // the same ordering bug as CBOS::Detect().)
  }
//+------------------------------------------------------------------+
void CFVG::UpdateAllStates()
  {
   for(int i = 0; i < m_zoneCount; i++)
      UpdateState(m_zones[i]);
  }
//+------------------------------------------------------------------+
void CFVG::UpdateState(FVGZone &zone)
  {
   if(zone.state == FVG_MITIGATED || zone.state == FVG_INVALIDATED)
      return; // terminal states — nothing to update
   int total = m_candles.Total();
   // Series-indexed newest-first: scan from now (0) backward. Once we
   // reach a bar older than the zone's creation time we can stop —
   // everything beyond that is even older (was "continue" in the
   // original, forcing a full unnecessary scan of the whole history
   // buffer on every OnCalculate call, for every zone).
   for(int bar = 0; bar < total; bar++)
     {
      CandleData cd = m_candles.GetCandle(bar);
      if(cd.time < zone.time)
         break;
      if(zone.dir == FVG_BULL)
        {
         if(cd.low <= zone.top && cd.high >= zone.bottom)
           {
            if(cd.close >= zone.top)
               zone.state = FVG_MITIGATED;
            else if(zone.state == FVG_FRESH)
               zone.state = FVG_TESTED;
           }
        }
      else
        {
         if(cd.high >= zone.bottom && cd.low <= zone.top)
           {
            if(cd.close <= zone.bottom)
               zone.state = FVG_MITIGATED;
            else if(zone.state == FVG_FRESH)
               zone.state = FVG_TESTED;
           }
        }
     }
  }
//+------------------------------------------------------------------+
FVGZone CFVG::GetZone(int i) const
  {
   FVGZone empty;
   ZeroMemory(empty);
   if(i < 0 || i >= m_zoneCount) return empty;
   return m_zones[i];
  }
#endif
//+------------------------------------------------------------------+
