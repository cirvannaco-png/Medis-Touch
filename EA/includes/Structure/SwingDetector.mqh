//+------------------------------------------------------------------+
//|                                        Structure/SwingDetector.mqh |
//+------------------------------------------------------------------+
#ifndef SWINGDETECTOR_MQH
#define SWINGDETECTOR_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"

class CSwingDetector
  {
private:
   CCandleData*      m_candles;
   int               m_strength;       // N left/right bars
   SwingPoint        m_swingHighs[];
   SwingPoint        m_swingLows[];
   int               m_highCount;
   int               m_lowCount;

   bool              IsSwingHigh(int idx);
   bool              IsSwingLow(int idx);
   double            CalcStrength(int idx);

public:
                     CSwingDetector();
   void              SetParameters(CCandleData* candleData, int strength = 3);
   void              Detect();

   int               HighCount() const { return m_highCount; }
   int               LowCount() const { return m_lowCount; }
   SwingPoint        GetHigh(int i) const;  // 0 = most recent
   SwingPoint        GetLow(int i) const;   // 0 = most recent
  };
//+------------------------------------------------------------------+
CSwingDetector::CSwingDetector()
  {
   m_candles = NULL;
   m_strength = 3;
   m_highCount = 0;
   m_lowCount = 0;
  }
//+------------------------------------------------------------------+
void CSwingDetector::SetParameters(CCandleData* candleData, int strength)
  {
   m_candles = candleData;
   m_strength = MathMax(1, strength);
  }
//+------------------------------------------------------------------+
// NOTE: series array convention — index 0 is the newest bar, increasing
// index moves further into the past. So "idx - i" (smaller index) is
// MORE recent than idx, and "idx + i" (larger index) is OLDER than idx.
bool CSwingDetector::IsSwingHigh(int idx)
  {
   if(m_candles == NULL) return false;
   int total = m_candles.Total();
   if(idx < m_strength || idx >= total - m_strength) return false;
   double high = m_candles.GetCandle(idx).high;
   for(int i = 1; i <= m_strength; i++)
     {
      if(m_candles.GetCandle(idx - i).high >= high) return false; // more recent side
      if(m_candles.GetCandle(idx + i).high >= high) return false; // older side
     }
   return true;
  }
//+------------------------------------------------------------------+
bool CSwingDetector::IsSwingLow(int idx)
  {
   if(m_candles == NULL) return false;
   int total = m_candles.Total();
   if(idx < m_strength || idx >= total - m_strength) return false;
   double low = m_candles.GetCandle(idx).low;
   for(int i = 1; i <= m_strength; i++)
     {
      if(m_candles.GetCandle(idx - i).low <= low) return false;
      if(m_candles.GetCandle(idx + i).low <= low) return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
double CSwingDetector::CalcStrength(int idx)
  {
   CandleData cd = m_candles.GetCandle(idx);
   double range = (cd.high - cd.low);
   double atr = cd.atr;
   if(atr <= 0) return 0.5;
   double ratio = range / atr;
   return MathMin(ratio, 1.0);
  }
//+------------------------------------------------------------------+
void CSwingDetector::Detect()
  {
   m_highCount = 0;
   m_lowCount = 0;
   if(m_candles == NULL) return;
   int total = m_candles.Total();
   if(total < 2 * m_strength + 1) return;
   ArrayResize(m_swingHighs, total);
   ArrayResize(m_swingLows, total);

   // Scan from oldest scannable bar to newest so results start in
   // chronological order (oldest first).
   for(int i = total - m_strength - 1; i >= m_strength; i--)
     {
      if(IsSwingHigh(i))
        {
         SwingPoint sp;
         sp.time = m_candles.GetCandle(i).time;
         sp.price = m_candles.GetCandle(i).high;
         sp.is_high = true;
         sp.bar_index = i;
         sp.strength = CalcStrength(i);
         m_swingHighs[m_highCount++] = sp;
        }
      if(IsSwingLow(i))
        {
         SwingPoint sp;
         sp.time = m_candles.GetCandle(i).time;
         sp.price = m_candles.GetCandle(i).low;
         sp.is_high = false;
         sp.bar_index = i;
         sp.strength = CalcStrength(i);
         m_swingLows[m_lowCount++] = sp;
        }
     }
   ArrayResize(m_swingHighs, m_highCount);
   ArrayResize(m_swingLows, m_lowCount);
   // Arrays are now newest-first already, since we scanned high bar_index
   // (older) down to low bar_index (newer) and appended in that order —
   // wait: we appended oldest-scanned-first meaning m_swingHighs[0] is the
   // OLDEST swing found. Reverse so index 0 = most recent, matching the
   // documented GetHigh()/GetLow() contract used by every other module.
   for(int j = 0; j < m_highCount / 2; j++)
     {
      SwingPoint t = m_swingHighs[j];
      m_swingHighs[j] = m_swingHighs[m_highCount - 1 - j];
      m_swingHighs[m_highCount - 1 - j] = t;
     }
   for(int j = 0; j < m_lowCount / 2; j++)
     {
      SwingPoint t = m_swingLows[j];
      m_swingLows[j] = m_swingLows[m_lowCount - 1 - j];
      m_swingLows[m_lowCount - 1 - j] = t;
     }
  }
//+------------------------------------------------------------------+
SwingPoint CSwingDetector::GetHigh(int i) const
  {
   SwingPoint empty;
   ZeroMemory(empty);
   if(i < 0 || i >= m_highCount) return empty;
   return m_swingHighs[i];
  }
//+------------------------------------------------------------------+
SwingPoint CSwingDetector::GetLow(int i) const
  {
   SwingPoint empty;
   ZeroMemory(empty);
   if(i < 0 || i >= m_lowCount) return empty;
   return m_swingLows[i];
  }
#endif
//+------------------------------------------------------------------+
