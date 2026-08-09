//+------------------------------------------------------------------+
//|                                    SmartMoney/FibonacciEngine.mqh |
//+------------------------------------------------------------------+
#ifndef FIBONACCIENGINE_MQH
#define FIBONACCIENGINE_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../Structure/SwingDetector.mqh"

// Fibonacci Engine — a LOCATION filter, never a signal generator. Anchors
// come only from confirmed swing highs/lows produced by CSwingDetector;
// manual anchor selection is deliberately not exposed anywhere in this
// class. For an uptrend leg: 0% retracement = the confirmed swing high,
// 100% = the confirmed swing low it retraced from (mirrored for a
// downtrend leg). Levels are always computed fresh from the live swing
// series — nothing here is cached or hand-placed.
struct FibLeg
  {
   bool              valid;
   bool              bullish;     // true = uptrend leg (retracement measured down from the high)
   double            lowPrice;
   double            highPrice;
   datetime          lowTime;
   datetime          highTime;
   int               lowBar;
   int               highBar;
  };

class CFibonacciEngine
  {
private:
   CSwingDetector*   m_swings;
   CCandleData*      m_candles;

   bool              FindLeg(bool forBuy, FibLeg &out) const;
   double            LevelPrice(const FibLeg &leg, double pct) const;

public:
                     CFibonacciEngine();
   void              Init(CSwingDetector* swings, CCandleData* candles);

   // CONFIRMATION filter (see gate convention, Core/Config.mqh) — fails
   // closed on purpose: no confirmed swing pair means no leg to measure.
   bool              GetLeg(bool forBuy, FibLeg &out) const { return FindLeg(forBuy, out); }
   double            RetracementPct(bool forBuy, double price) const; // 0 at the impulse extreme, 100 at the leg's origin, -1 if no leg
   ENUM_FIB_ZONE     Zone(bool forBuy, double price) const;
   bool              InPullbackZone(bool forBuy, double price, double zoneMinPct = 50.0, double zoneMaxPct = 61.8) const;
   double            NearestLevel(bool forBuy, double price, double &pctOut) const; // price of nearest of {38.2, 50, 61.8, 78.6}

   // 0-1 confluence score: 1.0 inside [zoneMinPct, zoneMaxPct], decaying
   // to 0 by the 38.2%/78.6% guard rails outside it. Diagnostic/ranking
   // only — see the gating discipline note in Analysis/Scoring.mqh.
   double            Score(bool forBuy, double price, double zoneMinPct = 50.0, double zoneMaxPct = 61.8) const;
  };
//+------------------------------------------------------------------+
CFibonacciEngine::CFibonacciEngine() : m_swings(NULL), m_candles(NULL) {}
//+------------------------------------------------------------------+
void CFibonacciEngine::Init(CSwingDetector* swings, CCandleData* candles)
  {
   m_swings = swings;
   m_candles = candles;
  }
//+------------------------------------------------------------------+
// forBuy (uptrend leg): anchor on the most recent confirmed swing high,
// then the nearest confirmed swing low OLDER than it (the low that
// started the impulse leg ending at that high).
// forBuy == false (downtrend leg): mirrored — most recent swing low, and
// the nearest older swing high that started the down-leg.
// NOTE: series convention (matches SwingDetector.mqh) — index 0 is the
// most recent point, and a LARGER bar_index means an OLDER bar.
bool CFibonacciEngine::FindLeg(bool forBuy, FibLeg &out) const
  {
   ZeroMemory(out);
   if(m_swings == NULL) return false;
   if(m_swings.HighCount() == 0 || m_swings.LowCount() == 0) return false;

   if(forBuy)
     {
      SwingPoint hi = m_swings.GetHigh(0);
      bool found = false;
      SwingPoint bestLow;
      for(int i = 0; i < m_swings.LowCount(); i++)
        {
         SwingPoint lo = m_swings.GetLow(i);
         if(lo.bar_index > hi.bar_index)          // older than the high
           {
            if(!found || lo.bar_index < bestLow.bar_index) { bestLow = lo; found = true; }
           }
        }
      if(!found) return false;
      out.valid = true;
      out.bullish = true;
      out.lowPrice = bestLow.price;
      out.highPrice = hi.price;
      out.lowTime = bestLow.time;
      out.highTime = hi.time;
      out.lowBar = bestLow.bar_index;
      out.highBar = hi.bar_index;
      return true;
     }
   else
     {
      SwingPoint lo = m_swings.GetLow(0);
      bool found = false;
      SwingPoint bestHigh;
      for(int i = 0; i < m_swings.HighCount(); i++)
        {
         SwingPoint hi2 = m_swings.GetHigh(i);
         if(hi2.bar_index > lo.bar_index)         // older than the low
           {
            if(!found || hi2.bar_index < bestHigh.bar_index) { bestHigh = hi2; found = true; }
           }
        }
      if(!found) return false;
      out.valid = true;
      out.bullish = false;
      out.lowPrice = lo.price;
      out.highPrice = bestHigh.price;
      out.lowTime = lo.time;
      out.highTime = bestHigh.time;
      out.lowBar = lo.bar_index;
      out.highBar = bestHigh.bar_index;
      return true;
     }
  }
//+------------------------------------------------------------------+
// pct is a retracement percentage (0-100): 0 = the impulse extreme (the
// high in an uptrend leg, the low in a downtrend leg), 100 = the leg's
// origin.
double CFibonacciEngine::LevelPrice(const FibLeg &leg, double pct) const
  {
   double range = leg.highPrice - leg.lowPrice;
   double frac = pct / 100.0;
   if(leg.bullish)
      return leg.highPrice - frac * range;   // retracing down from the high
   else
      return leg.lowPrice + frac * range;    // retracing up from the low
  }
//+------------------------------------------------------------------+
double CFibonacciEngine::RetracementPct(bool forBuy, double price) const
  {
   FibLeg leg;
   if(!FindLeg(forBuy, leg)) return -1.0;
   double range = leg.highPrice - leg.lowPrice;
   if(range <= 0) return -1.0;
   double pct = leg.bullish ? (leg.highPrice - price) / range * 100.0
                            : (price - leg.lowPrice) / range * 100.0;
   return pct;
  }
//+------------------------------------------------------------------+
// Discount = price has pulled back deep into the leg (cheap relative to
// the impulse — favorable for the trend direction). Premium = still
// shallow / close to the impulse extreme (expensive). Matches the same
// discount/premium vocabulary SmartMoney/PremiumDiscount.mqh uses for the
// (separate) inducement-leg gate — this one is swing-anchored, that one
// is impulse-anchored; they will usually agree but are not the same leg.
ENUM_FIB_ZONE CFibonacciEngine::Zone(bool forBuy, double price) const
  {
   double pct = RetracementPct(forBuy, price);
   if(pct < 0) return FIB_ZONE_UNDEFINED;
   if(pct >= 61.8) return FIB_ZONE_DISCOUNT;
   if(pct >= 38.2) return FIB_ZONE_NEUTRAL;
   return FIB_ZONE_PREMIUM;
  }
//+------------------------------------------------------------------+
bool CFibonacciEngine::InPullbackZone(bool forBuy, double price, double zoneMinPct, double zoneMaxPct) const
  {
   double pct = RetracementPct(forBuy, price);
   if(pct < 0) return false;
   double lo = MathMin(zoneMinPct, zoneMaxPct);
   double hi = MathMax(zoneMinPct, zoneMaxPct);
   return (pct >= lo && pct <= hi);
  }
//+------------------------------------------------------------------+
double CFibonacciEngine::NearestLevel(bool forBuy, double price, double &pctOut) const
  {
   FibLeg leg;
   if(!FindLeg(forBuy, leg)) { pctOut = -1.0; return 0.0; }
   double levels[4] = {38.2, 50.0, 61.8, 78.6};
   double bestDist = -1.0;
   double bestPrice = 0.0;
   double bestPct = -1.0;
   for(int i = 0; i < 4; i++)
     {
      double lvlPrice = LevelPrice(leg, levels[i]);
      double dist = MathAbs(price - lvlPrice);
      if(bestDist < 0 || dist < bestDist) { bestDist = dist; bestPrice = lvlPrice; bestPct = levels[i]; }
     }
   pctOut = bestPct;
   return bestPrice;
  }
//+------------------------------------------------------------------+
double CFibonacciEngine::Score(bool forBuy, double price, double zoneMinPct, double zoneMaxPct) const
  {
   double pct = RetracementPct(forBuy, price);
   if(pct < 0) return 0.0;
   double lo = MathMin(zoneMinPct, zoneMaxPct);
   double hi = MathMax(zoneMinPct, zoneMaxPct);
   if(pct >= lo && pct <= hi) return 1.0;

   if(pct < lo)
     {
      double floor = 38.2;
      if(pct <= floor) return 0.0;
      return (pct - floor) / (lo - floor);
     }
   else
     {
      double ceilPct = 78.6;
      if(pct >= ceilPct) return 0.0;
      return (ceilPct - pct) / (ceilPct - hi);
     }
  }
#endif
//+------------------------------------------------------------------+
