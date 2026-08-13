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

   double            BreakoutStrength(int shift, double atr, const CandleData &cd, double brokenLevel) const;

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
// (a) how far price closed beyond the broken level, relative to ATR, and
// (b) whether the breakout candle traded on above-average volume vs the
// prior 10 bars.
double CBOS::BreakoutStrength(int shift, double atr, const CandleData &cd, double brokenLevel) const
  {
   double breakoutDistATR = MathAbs(cd.close - brokenLevel) / atr;
   double avgVol = 0.0;
   int n = 0;
   for(int b = shift + 1; b <= shift + 10 && b < m_candles.Total(); b++)
     {
      avgVol += (double)m_candles.GetCandle(b).tick_volume;
      n++;
     }
   double volRatio = (n > 0 && avgVol > 0) ? ((double)cd.tick_volume / (avgVol / n)) : 1.0;
   double s = 0.6 * MathMin(breakoutDistATR / 1.0, 1.0) + 0.4 * MathMin(volRatio / 2.0, 1.0);
   return MathMax(0.0, MathMin(s, 1.0));
  }
//+------------------------------------------------------------------+
// FIX (audit #7 — lookahead bias): the previous implementation picked
// ONE swing — "the most recent lower high in TODAY's fully up-to-date
// swing list" — and then scanned every historical bar (i = 1..total-1)
// checking whether ITS close broke THAT SAME swing. Two bars from
// entirely different points in history were being judged against a
// single "lower high" that may not have existed, or even been
// CONFIRMED yet (a swing needs `strength` bars of later data before
// it's a swing at all), at the time those older bars actually printed.
// That's lookahead: a historical BOS could be "confirmed" using
// structure the market didn't have yet.
//
// This rewrite is a single chronological forward pass (oldest bar to
// newest). It tracks the currently active, not-yet-broken "lower high" /
// "higher low" candidate, but only ever promotes a swing into that role
// once the swing itself is CONFIRMED as of the current bar (bar_index -
// strength >= current shift — i.e. `strength` bars have already printed
// after it). A BOS event is only recorded on the bar that closes beyond
// an ALREADY-CONFIRMED candidate, in time order. This is chronologically
// sound: every BOS event only ever depends on data that existed on or
// before its own bar.
void CBOS::Detect()
  {
   m_bosCount = 0;
   if(m_swings == NULL || m_candles == NULL) return;
   int total = m_candles.Total();
   if(total < 2) return;
   int strength = m_swings.Strength();

   int nHighs = m_swings.HighCount();
   int nLows  = m_swings.LowCount();

   // GetHigh(0)/GetLow(0) = newest, larger index = older. Reverse into
   // oldest-first order so we can walk them alongside the chronological
   // (oldest -> newest) candle scan below.
   SwingPoint highsChrono[];
   ArrayResize(highsChrono, nHighs);
   for(int i = 0; i < nHighs; i++) highsChrono[i] = m_swings.GetHigh(nHighs - 1 - i);
   SwingPoint lowsChrono[];
   ArrayResize(lowsChrono, nLows);
   for(int i = 0; i < nLows; i++) lowsChrono[i] = m_swings.GetLow(nLows - 1 - i);

   int highPtr = 0, lowPtr = 0;
   bool havePrevHigh = false, havePrevLow = false;
   SwingPoint prevHigh, prevLow;
   bool haveActiveLowerHigh = false, haveActiveHigherLow = false;
   SwingPoint activeLowerHigh, activeHigherLow;

   BOSEvent chrono[]; // built oldest -> newest, reversed into m_bosList at the end
   ArrayResize(chrono, total);
   int chronoCount = 0;

   for(int shift = total - 1; shift >= 1; shift--) // oldest -> newest
     {
      // Confirm any swings whose confirmation point has now arrived
      // (chronologically: a swing at bar_index needs `strength` later
      // bars to exist before it counts as confirmed structure).
      while(highPtr < nHighs && (highsChrono[highPtr].bar_index - strength) >= shift)
        {
         SwingPoint h = highsChrono[highPtr];
         if(havePrevHigh && h.price < prevHigh.price) // freshly-confirmed lower high
           {
            activeLowerHigh = h;
            haveActiveLowerHigh = true;
           }
         prevHigh = h;
         havePrevHigh = true;
         highPtr++;
        }
      while(lowPtr < nLows && (lowsChrono[lowPtr].bar_index - strength) >= shift)
        {
         SwingPoint l = lowsChrono[lowPtr];
         if(havePrevLow && l.price > prevLow.price) // freshly-confirmed higher low
           {
            activeHigherLow = l;
            haveActiveHigherLow = true;
           }
         prevLow = l;
         havePrevLow = true;
         lowPtr++;
        }

      double atr = m_candles.GetATR(shift);
      if(atr <= 0) continue;
      CandleData cd = m_candles.GetCandle(shift);

      if(haveActiveLowerHigh)
        {
         double threshold = activeLowerHigh.price + 0.1 * atr;
         if(cd.close > threshold)
           {
            BOSEvent ev;
            ev.time = cd.time;
            ev.price = cd.close;
            ev.is_bullish = true;
            ev.strength = BreakoutStrength(shift, atr, cd, activeLowerHigh.price);
            ev.bar_index = shift;
            ev.label = "BOS \u2191";
            chrono[chronoCount++] = ev;
            haveActiveLowerHigh = false; // consumed — next lower high (if any) becomes the new candidate
           }
        }
      if(haveActiveHigherLow)
        {
         double threshold = activeHigherLow.price - 0.1 * atr;
         if(cd.close < threshold)
           {
            BOSEvent ev;
            ev.time = cd.time;
            ev.price = cd.close;
            ev.is_bullish = false;
            ev.strength = BreakoutStrength(shift, atr, cd, activeHigherLow.price);
            ev.bar_index = shift;
            ev.label = "BOS \u2193";
            chrono[chronoCount++] = ev;
            haveActiveHigherLow = false;
           }
        }
     }

   // chrono[] is oldest -> newest; GetBOS(0) must return the newest, so reverse on the way out.
   ArrayResize(m_bosList, chronoCount);
   for(int i = 0; i < chronoCount; i++)
      m_bosList[i] = chrono[chronoCount - 1 - i];
   m_bosCount = chronoCount;
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
