//+------------------------------------------------------------------+
//|                                                   Structure/BOS.mqh |
//+------------------------------------------------------------------+
#ifndef BOS_MQH
#define BOS_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "SwingDetector.mqh"

class CBOS
  {
private:
   CSwingDetector*   m_swings;
   CCandleData*      m_candles;
   BOSEvent          m_bosList[];
   int               m_bosCount;

   bool              IsBullishBOS(int shift, double &outStrength);
   bool              IsBearishBOS(int shift, double &outStrength);

public:
                     CBOS();
   void              Init(CSwingDetector* swingDetector, CCandleData* candleData);
   void              Detect();
   int               Count() const { return m_bosCount; }
   BOSEvent          GetBOS(int i) const;  // 0 = most recent
  };
//+------------------------------------------------------------------+
CBOS::CBOS() : m_swings(NULL), m_candles(NULL), m_bosCount(0) {}
void CBOS::Init(CSwingDetector* swingDetector, CCandleData* candleData)
  {
   m_swings = swingDetector;
   m_candles = candleData;
  }
//+------------------------------------------------------------------+
// Bullish BOS: find the most recent "lower high" in the swing-high
// sequence (a correction against an uptrend, or the last defended high
// of a downtrend) and check whether price has now closed decisively
// above it.
bool CBOS::IsBullishBOS(int shift, double &outStrength)
  {
   outStrength = 0.0;
   if(m_swings == NULL || m_candles == NULL) return false;
   int totalHighs = m_swings.HighCount();
   if(totalHighs < 2) return false;

   int relevantIdx = -1;
   for(int i = 0; i < totalHighs - 1; i++)
     {
      SwingPoint curr = m_swings.GetHigh(i);
      SwingPoint prev = m_swings.GetHigh(i + 1);
      if(curr.price < prev.price) // lower high
        {
         relevantIdx = i;
         break;
        }
     }
   if(relevantIdx < 0) return false;

   SwingPoint swingHigh = m_swings.GetHigh(relevantIdx);
   CandleData cd = m_candles.GetCandle(shift);
   double atr = m_candles.GetATR(shift);
   if(atr <= 0) return false;
   double threshold = swingHigh.price + 0.1 * atr;
   if(cd.close <= threshold) return false;

   // FIX: strength used to be volume/MathMax(1,volume), which is always
   // ~1.0 — a fake metric. Real strength blends (a) how far price closed
   // beyond the broken level, relative to ATR, and (b) whether the
   // breakout candle traded on above-average volume vs the prior 10 bars.
   double breakoutDistATR = (cd.close - swingHigh.price) / atr;
   double avgVol = 0.0;
   int n = 0;
   for(int b = shift + 1; b <= shift + 10 && b < m_candles.Total(); b++)
     {
      avgVol += (double)m_candles.GetCandle(b).tick_volume;
      n++;
     }
   double volRatio = (n > 0 && avgVol > 0) ? ((double)cd.tick_volume / (avgVol / n)) : 1.0;
   double s = 0.6 * MathMin(breakoutDistATR / 1.0, 1.0) + 0.4 * MathMin(volRatio / 2.0, 1.0);
   outStrength = MathMax(0.0, MathMin(s, 1.0));
   return true;
  }
//+------------------------------------------------------------------+
// Bearish BOS: mirror of the bullish case — find the most recent
// "higher low" (a correction against a downtrend, or the last defended
// low of an uptrend) and check whether price has now closed decisively
// below it.
bool CBOS::IsBearishBOS(int shift, double &outStrength)
  {
   outStrength = 0.0;
   if(m_swings == NULL || m_candles == NULL) return false;
   int totalLows = m_swings.LowCount();
   if(totalLows < 2) return false;

   int relevantIdx = -1;
   for(int i = 0; i < totalLows - 1; i++)
     {
      SwingPoint curr = m_swings.GetLow(i);
      SwingPoint prev = m_swings.GetLow(i + 1);
      if(curr.price > prev.price) // higher low
        {
         relevantIdx = i;
         break;
        }
     }
   if(relevantIdx < 0) return false;

   SwingPoint swingLow = m_swings.GetLow(relevantIdx);
   CandleData cd = m_candles.GetCandle(shift);
   double atr = m_candles.GetATR(shift);
   if(atr <= 0) return false;
   double threshold = swingLow.price - 0.1 * atr;
   if(cd.close >= threshold) return false;

   double breakoutDistATR = (swingLow.price - cd.close) / atr;
   double avgVol = 0.0;
   int n = 0;
   for(int b = shift + 1; b <= shift + 10 && b < m_candles.Total(); b++)
     {
      avgVol += (double)m_candles.GetCandle(b).tick_volume;
      n++;
     }
   double volRatio = (n > 0 && avgVol > 0) ? ((double)cd.tick_volume / (avgVol / n)) : 1.0;
   double s = 0.6 * MathMin(breakoutDistATR / 1.0, 1.0) + 0.4 * MathMin(volRatio / 2.0, 1.0);
   outStrength = MathMax(0.0, MathMin(s, 1.0));
   return true;
  }
//+------------------------------------------------------------------+
void CBOS::Detect()
  {
   m_bosCount = 0;
   if(m_candles == NULL) return;
   int total = m_candles.Total();
   ArrayResize(m_bosList, total);
   for(int i = 1; i < total; i++)
     {
      double strength = 0.0;
      if(IsBullishBOS(i, strength))
        {
         BOSEvent ev;
         ev.time = m_candles.GetCandle(i).time;
         ev.price = m_candles.GetCandle(i).close;
         ev.is_bullish = true;
         ev.strength = strength;
         ev.bar_index = i;
         ev.label = "BOS \u2191";
         m_bosList[m_bosCount++] = ev;
        }
      else if(IsBearishBOS(i, strength))
        {
         BOSEvent ev;
         ev.time = m_candles.GetCandle(i).time;
         ev.price = m_candles.GetCandle(i).close;
         ev.is_bullish = false;
         ev.strength = strength;
         ev.bar_index = i;
         ev.label = "BOS \u2193";
         m_bosList[m_bosCount++] = ev;
        }
     }
   ArrayResize(m_bosList, m_bosCount);
   // NOTE: no reversal needed here. The loop above runs i = 1 .. total-1,
   // i.e. from the most recent bar toward the oldest (series-indexed:
   // smaller shift = more recent). So events are appended in
   // most-recent-first order already. The original codebase reversed
   // this array unconditionally (copying the pattern from SwingDetector,
   // whose loop runs in the OPPOSITE direction) which silently inverted
   // GetBOS(0) to return the OLDEST break instead of the newest —
   // a real bug, not just a style issue, since every downstream consumer
   // (TrendEngine, Scoring, Visuals) assumes index 0 is the latest event.
  }
//+------------------------------------------------------------------+
BOSEvent CBOS::GetBOS(int i) const
  {
   BOSEvent empty;
   ZeroMemory(empty);
   if(i < 0 || i >= m_bosCount) return empty;
   return m_bosList[i];
  }
#endif
//+------------------------------------------------------------------+
