//+------------------------------------------------------------------+
//|                                    SmartMoney/ValueAreaEngine.mqh |
//+------------------------------------------------------------------+
#ifndef VALUEAREAENGINE_MQH
#define VALUEAREAENGINE_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"

// Value Area Engine — "is price cheap or expensive relative to where
// most trading actually happened recently?" A location filter, same
// discipline as Volume and Fibonacci: it never generates a signal, it
// only says whether the price a setup wants to trade at sits inside,
// below, or above the recent Value Area.
//
// Standard volume-profile construction:
//   1. Bucket the lookback window's high/low range into N price bins.
//   2. Distribute each bar's volume across every bin its range touches
//      (evenly split across touched bins — an approximation, since MT5
//      doesn't expose true intrabar trade-price volume without a tick
//      history feed; see the caveat below).
//   3. POC = the bin with the most accumulated volume.
//   4. Value Area = POC bin, expanded outward one bin at a time — always
//      toward whichever neighboring bin (above or below the current
//      envelope) carries more volume — until the accumulated volume
//      reaches valueAreaPercent (default 70%, the standard Market
//      Profile convention) of the window's total.
//
// CAVEAT: this is a bar-range approximation of a true tick-built volume
// profile. It distributes each bar's tick_volume uniformly across the
// bins its (low, high) span touches, which is standard practice for
// building a profile from OHLCV bars but is not the same as a profile
// built from actual trade prints. Treat POC/VAH/VAL as a location
// estimate, not an exact figure — same epistemic status as RVOL's
// tick_volume proxy in VolumeEngine.mqh.
class CValueAreaEngine
  {
private:
   CCandleData*      m_candles;
   int               m_lookbackBars;
   int               m_numBins;
   double            m_valueAreaPercent;   // fraction 0-1, e.g. 0.70

   bool              m_valid;
   double            m_poc;
   double            m_vah;
   double            m_val;
   datetime          m_lastBarTime;        // avoids recomputing the profile more than once per bar

public:
                     CValueAreaEngine();
   void              Init(CCandleData* candles, int lookbackBars = 100, int numBins = 24, double valueAreaPercent = 0.70);
   void              Compute(bool forceRecompute = false);

   bool              IsValid() const { return m_valid; }
   double            POC() const { return m_poc; }
   double            VAH() const { return m_vah; }
   double            VAL() const { return m_val; }

   ENUM_VALUE_AREA_ZONE Zone(double price) const;
   // BUY: price at/below VAH (inside or below Value Area — "discount").
   // SELL: price at/above VAL (inside or above Value Area — "premium").
   // Mirrors the doc's Final Entry Rule: "Price below or within Value
   // Area." Returns true (don't block) if no valid profile exists yet.
   // LOCATION filter (see gate convention, Core/Config.mqh) — fails open
   // for the same reason as CPremiumDiscount::OK(): no profile, no wrong side.
   bool              LocationOK(bool forBuy, double price) const;

   // 0-1 confluence score for ranking only — 1.0 at POC, decaying to 0 at
   // the far edge of the Value Area, 0 outside it entirely.
   double            Score(bool forBuy, double price) const;
  };
//+------------------------------------------------------------------+
CValueAreaEngine::CValueAreaEngine() : m_candles(NULL), m_lookbackBars(100), m_numBins(24),
                                        m_valueAreaPercent(0.70), m_valid(false),
                                        m_poc(0.0), m_vah(0.0), m_val(0.0), m_lastBarTime(0) {}
//+------------------------------------------------------------------+
void CValueAreaEngine::Init(CCandleData* candles, int lookbackBars, int numBins, double valueAreaPercent)
  {
   m_candles = candles;
   m_lookbackBars = MathMax(10, lookbackBars);
   m_numBins = MathMax(5, numBins);
   m_valueAreaPercent = (valueAreaPercent > 0.0 && valueAreaPercent < 1.0) ? valueAreaPercent : 0.70;
   m_valid = false;
   m_lastBarTime = 0;
  }
//+------------------------------------------------------------------+
void CValueAreaEngine::Compute(bool forceRecompute)
  {
   m_valid = false;
   if(m_candles == NULL || m_candles.Total() < 10) return;

   // Rebuilding a 24-bin histogram over 100 bars every tick is wasted
   // work — the profile only needs to change once a new bar closes.
   datetime barTime = m_candles.GetCandle(0).time;
   if(!forceRecompute && barTime == m_lastBarTime && m_poc != 0.0)
     {
      m_valid = true; // last computed profile still applies to this bar
      return;
     }

   int total = m_candles.Total();
   int bars = MathMin(m_lookbackBars, total);
   if(bars < 10) return;

   double rangeHigh = -DBL_MAX, rangeLow = DBL_MAX;
   for(int i = 0; i < bars; i++)
     {
      CandleData cd = m_candles.GetCandle(i);
      if(cd.high > rangeHigh) rangeHigh = cd.high;
      if(cd.low  < rangeLow)  rangeLow  = cd.low;
     }
   double range = rangeHigh - rangeLow;
   if(range <= 0) return;

   double binSize = range / m_numBins;
   if(binSize <= 0) return;

   double volumes[];
   ArrayResize(volumes, m_numBins);
   ArrayInitialize(volumes, 0.0);

   for(int i = 0; i < bars; i++)
     {
      CandleData cd = m_candles.GetCandle(i);
      double vol = (double)cd.tick_volume;
      if(vol <= 0) continue;

      if(cd.high <= cd.low)
        {
         int singleBin = (int)((cd.close - rangeLow) / binSize);
         singleBin = (int)MathMax(0, MathMin(m_numBins - 1, singleBin));
         volumes[singleBin] += vol;
         continue;
        }

      int startBin = (int)((cd.low  - rangeLow) / binSize);
      int endBin   = (int)((cd.high - rangeLow) / binSize);
      startBin = (int)MathMax(0, MathMin(m_numBins - 1, startBin));
      endBin   = (int)MathMax(0, MathMin(m_numBins - 1, endBin));
      if(endBin < startBin) { int t = startBin; startBin = endBin; endBin = t; }

      int touched = endBin - startBin + 1;
      double volPerBin = vol / touched;
      for(int b = startBin; b <= endBin; b++)
         volumes[b] += volPerBin;
     }

   double totalVol = 0.0;
   int pocBin = 0;
   double pocVol = -1.0;
   for(int b = 0; b < m_numBins; b++)
     {
      totalVol += volumes[b];
      if(volumes[b] > pocVol) { pocVol = volumes[b]; pocBin = b; }
     }
   if(totalVol <= 0) return;

   int lowIdx = pocBin, highIdx = pocBin;
   double cumVol = volumes[pocBin];
   double targetVol = totalVol * m_valueAreaPercent;

   while(cumVol < targetVol && (lowIdx > 0 || highIdx < m_numBins - 1))
     {
      double volBelow = (lowIdx > 0) ? volumes[lowIdx - 1] : -1.0;
      double volAbove = (highIdx < m_numBins - 1) ? volumes[highIdx + 1] : -1.0;
      if(volBelow < 0 && volAbove < 0) break;
      if(volBelow >= volAbove) { lowIdx--; cumVol += volumes[lowIdx]; }
      else                     { highIdx++; cumVol += volumes[highIdx]; }
     }

   m_val = rangeLow + lowIdx * binSize;
   m_vah = rangeLow + (highIdx + 1) * binSize;
   m_poc = rangeLow + (pocBin + 0.5) * binSize;
   m_lastBarTime = barTime;
   m_valid = true;
  }
//+------------------------------------------------------------------+
ENUM_VALUE_AREA_ZONE CValueAreaEngine::Zone(double price) const
  {
   if(!m_valid) return VA_ZONE_UNDEFINED;
   if(price > m_vah) return VA_ZONE_ABOVE;   // premium — expensive relative to recent fair value
   if(price < m_val) return VA_ZONE_BELOW;   // discount — cheap relative to recent fair value
   return VA_ZONE_INSIDE;
  }
//+------------------------------------------------------------------+
bool CValueAreaEngine::LocationOK(bool forBuy, double price) const
  {
   if(!m_valid) return true; // no profile yet — don't block on missing data
   ENUM_VALUE_AREA_ZONE z = Zone(price);
   if(forBuy)  return (z == VA_ZONE_INSIDE || z == VA_ZONE_BELOW);
   else        return (z == VA_ZONE_INSIDE || z == VA_ZONE_ABOVE);
  }
//+------------------------------------------------------------------+
double CValueAreaEngine::Score(bool forBuy, double price) const
  {
   if(!m_valid) return 0.0;
   if(!LocationOK(forBuy, price)) return 0.0;
   if(price >= m_val && price <= m_vah)
     {
      double half = (m_vah - m_val) / 2.0;
      if(half <= 0) return 1.0;
      double distFromPOC = MathAbs(price - m_poc);
      return MathMax(0.0, 1.0 - distFromPOC / half);
     }
   return 1.0; // outside the VA but on the favorable (LocationOK) side — full credit, same as a fresh discount/premium read
  }
#endif
//+------------------------------------------------------------------+
