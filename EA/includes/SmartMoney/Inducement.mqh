//+------------------------------------------------------------------+
//|                                          SmartMoney/Inducement.mqh |
//+------------------------------------------------------------------+
#ifndef INDUCEMENT_MQH
#define INDUCEMENT_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"

// Validates the sequence: Impulse -> Internal pullback structure ->
// Internal liquidity sweep (inducement) -> minor BOS -> only then is a
// setup "confirmed". This turns the indicator from a feature detector
// (does an FVG exist near price?) into a decision engine (did price
// actually get manipulated into a stop run before the real move?).
//
// SCOPE / HONEST LIMITATIONS:
//  - All detection here runs on ONE timeframe (whatever CCandleData this
//    is Init()'d with — normally the FVG/entry timeframe, since that's
//    where the setup actually triggers). It does not cross-check the
//    impulse against a higher timeframe.
//  - "Minor" structure is a local 1-bar fractal (compare each bar only to
//    its immediate left/right neighbor), deliberately looser than the
//    swing detector used elsewhere (which defaults to 3 bars) — the whole
//    point of this module is to see the SMALL structure inside a pullback
//    that the main SwingDetector is tuned to ignore.
//  - "Equal" highs/lows use the same ATR-fraction tolerance band as
//    Liquidity.mqh's internal pools, passed in as equalTolATR, so the two
//    concepts stay consistent with each other.
class CInducement
  {
private:
   CCandleData*      m_candles;
   int               m_lookbackBars;
   double            m_impulseATRMult;   // min (bar range / ATR) to qualify as a displacement bar
   double            m_impulseBodyRatio; // min body/range ratio for a displacement bar
   double            m_equalTolATR;      // tolerance band for "equal" highs/lows, as a fraction of ATR
   int               m_maxLegExtend;     // how many bars a leg can be extended outward while still qualifying

   bool              IsDisplacementBar(int idx, bool bullish);
   bool              FindImpulse(bool bullish, ImpulseLeg &leg);
   bool              FindMinorSwing(int idx, bool wantHigh); // local 1-bar fractal
   bool              FindEqualPair(bool wantLows, int scanFrom, int scanTo, double atr,
                                   double &poolPrice, int &nearIdx, int &farIdx);

public:
                     CInducement();
   void              Init(CCandleData* candles, int lookbackBars = 40, double impulseATRMult = 1.2,
                          double impulseBodyRatio = 0.6, double equalTolATR = 0.2, int maxLegExtend = 10);
   InducementResult  Validate(bool forBuy);
  };
//+------------------------------------------------------------------+
CInducement::CInducement() : m_candles(NULL), m_lookbackBars(40), m_impulseATRMult(1.2),
                              m_impulseBodyRatio(0.6), m_equalTolATR(0.2), m_maxLegExtend(10) {}
//+------------------------------------------------------------------+
void CInducement::Init(CCandleData* candles, int lookbackBars, double impulseATRMult,
                       double impulseBodyRatio, double equalTolATR, int maxLegExtend)
  {
   m_candles = candles;
   m_lookbackBars = MathMax(10, lookbackBars);
   m_impulseATRMult = impulseATRMult;
   m_impulseBodyRatio = impulseBodyRatio;
   m_equalTolATR = equalTolATR;
   m_maxLegExtend = MathMax(2, maxLegExtend);
  }
//+------------------------------------------------------------------+
bool CInducement::IsDisplacementBar(int idx, bool bullish)
  {
   if(m_candles == NULL) return false;
   CandleData cd = m_candles.GetCandle(idx);
   double atr = m_candles.GetATR(idx);
   if(atr <= 0) return false;
   double range = cd.high - cd.low;
   if(range <= 0) return false;
   double body = MathAbs(cd.close - cd.open);
   double bodyRatio = body / range;
   bool directional = bullish ? (cd.close > cd.open) : (cd.close < cd.open);
   if(!directional) return false;
   if(range / atr < m_impulseATRMult) return false;
   if(bodyRatio < m_impulseBodyRatio) return false;
   // Opposite wick should be small — a big rejection wick against the
   // move undercuts the "displacement" read even if the body qualifies.
   double oppWick = bullish ? (cd.open - cd.low) : (cd.high - cd.open);
   if(oppWick > 0.3 * range) return false;
   return true;
  }
//+------------------------------------------------------------------+
// Scans the lookback window for a qualifying displacement bar, then
// extends the leg outward (toward more-recent AND toward older bars)
// while price keeps making new extremes in the same direction, so the
// leg's start/end prices bound the whole impulse move, not just the one
// bar that tripped the threshold.
bool CInducement::FindImpulse(bool bullish, ImpulseLeg &leg)
  {
   ZeroMemory(leg);
   if(m_candles == NULL) return false;
   int total = m_candles.Total();
   int scanLimit = MathMin(m_lookbackBars, total - 1);

   for(int i = 1; i <= scanLimit; i++)
     {
      if(!IsDisplacementBar(i, bullish)) continue;

      int newerBar = i; // extend toward index 0 (more recent)
      int olderBar = i; // extend toward higher index (older)
      double bestExtreme = bullish ? m_candles.GetCandle(i).high : m_candles.GetCandle(i).low;

      for(int k = i - 1; k >= MathMax(0, i - m_maxLegExtend); k--)
        {
         CandleData cd = m_candles.GetCandle(k);
         bool extends = bullish ? (cd.high >= bestExtreme) : (cd.low <= bestExtreme);
         if(!extends) break;
         bestExtreme = bullish ? cd.high : cd.low;
         newerBar = k;
        }
      double oldExtreme = bullish ? m_candles.GetCandle(i).low : m_candles.GetCandle(i).high;
      for(int k = i + 1; k <= MathMin(total - 1, i + m_maxLegExtend); k++)
        {
         CandleData cd = m_candles.GetCandle(k);
         bool extends = bullish ? (cd.low <= oldExtreme) : (cd.high >= oldExtreme);
         if(!extends) break;
         oldExtreme = bullish ? cd.low : cd.high;
         olderBar = k;
        }

      leg.valid = true;
      leg.start_bar = olderBar;
      leg.end_bar = newerBar;
      leg.start_time = m_candles.GetCandle(olderBar).time;
      leg.end_time = m_candles.GetCandle(newerBar).time;
      leg.start_price = oldExtreme;
      leg.end_price = bestExtreme;
      leg.bullish = bullish;

      double atr = m_candles.GetATR(i);
      double distATR = (atr > 0) ? MathAbs(leg.end_price - leg.start_price) / atr : 0.0;
      leg.strength = MathMax(0.0, MathMin(distATR / 3.0, 1.0));
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
// Local 1-bar fractal: idx is a minor swing high/low if it beats its
// immediate left AND right neighbor. Deliberately tighter than the main
// SwingDetector (strength 3) — this is meant to catch the small internal
// structure a pullback makes, not the major structure.
bool CInducement::FindMinorSwing(int idx, bool wantHigh)
  {
   if(m_candles == NULL) return false;
   int total = m_candles.Total();
   if(idx < 1 || idx >= total - 1) return false;
   if(wantHigh)
     {
      double h = m_candles.GetCandle(idx).high;
      return (h >= m_candles.GetCandle(idx - 1).high && h >= m_candles.GetCandle(idx + 1).high);
     }
   double l = m_candles.GetCandle(idx).low;
   return (l <= m_candles.GetCandle(idx - 1).low && l <= m_candles.GetCandle(idx + 1).low);
  }
//+------------------------------------------------------------------+
// Scans [scanFrom, scanTo] (series indices, scanFrom = more recent) for
// two minor swings of the requested type whose prices sit within
// m_equalTolATR * atr of each other — an "equal highs/lows" pool, the
// classic resting-liquidity signature.
bool CInducement::FindEqualPair(bool wantLows, int scanFrom, int scanTo, double atr,
                                double &poolPrice, int &nearIdx, int &farIdx)
  {
   poolPrice = 0.0; nearIdx = -1; farIdx = -1;
   if(m_candles == NULL || atr <= 0) return false;
   double band = m_equalTolATR * atr;

   int found[]; ArrayResize(found, 0);
   for(int i = scanFrom; i <= scanTo; i++)
     {
      if(!FindMinorSwing(i, wantLows ? false : true)) continue; // wantLows -> look for swing LOWS
      int n = ArraySize(found);
      ArrayResize(found, n + 1);
      found[n] = i;
     }
   int fc = ArraySize(found);
   for(int a = 0; a < fc - 1; a++)
     {
      double pa = wantLows ? m_candles.GetCandle(found[a]).low : m_candles.GetCandle(found[a]).high;
      for(int b = a + 1; b < fc; b++)
        {
         double pb = wantLows ? m_candles.GetCandle(found[b]).low : m_candles.GetCandle(found[b]).high;
         if(MathAbs(pa - pb) <= band)
           {
            nearIdx = MathMin(found[a], found[b]);
            farIdx  = MathMax(found[a], found[b]);
            poolPrice = wantLows ? MathMin(pa, pb) : MathMax(pa, pb);
            return true;
           }
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
InducementResult CInducement::Validate(bool forBuy)
  {
   InducementResult r;
   ZeroMemory(r);
   if(m_candles == NULL || m_candles.Total() < 20)
     {
      r.reason = "Not enough bars";
      return r;
     }

   ImpulseLeg leg;
   if(!FindImpulse(forBuy, leg))
     {
      r.reason = "No qualifying impulse (displacement) found in lookback window";
      return r;
     }
   r.impulseFound = true;
   r.impulseScore = 15.0;

   // Pullback/continuation region: everything more recent than the
   // impulse's newer edge, i.e. series indices [0, leg.end_bar - 1].
   int pullbackTo = leg.end_bar - 1;
   if(pullbackTo < 2)
     {
      r.reason = "Impulse too recent — no pullback bars to inspect yet";
      return r;
     }

   double atr = m_candles.GetATR(leg.end_bar);
   if(atr <= 0)
     {
      r.reason = "ATR unavailable at impulse edge";
      return r;
     }

   // Bullish impulse -> look for equal LOWS in the pullback (resting
   // sell-side liquidity that a stop-hunt would sweep before continuing
   // up). Bearish impulse -> equal HIGHS.
   double poolPrice; int nearIdx, farIdx;
   bool structureFound = FindEqualPair(forBuy /*wantLows*/, 0, pullbackTo, atr, poolPrice, nearIdx, farIdx);
   r.internalStructureFound = structureFound;
   r.structureScore = structureFound ? 10.0 : 0.0;
   if(!structureFound)
     {
      r.reason = "Impulse found, but no internal equal-highs/lows structure formed in the pullback";
      return r;
     }

   // Sweep: scan from the more-recent equal swing forward to now (index 0)
   // for a bar that wicks beyond the pool and closes back inside it.
   bool sweepFound = false;
   double sweepStrength = 0.0;
   int sweepBarIdx = -1;
   for(int i = nearIdx - 1; i >= 0; i--)
     {
      CandleData cd = m_candles.GetCandle(i);
      double barATR = m_candles.GetATR(i);
      if(barATR <= 0) continue;
      if(forBuy)
        {
         if(cd.low < poolPrice && cd.close > poolPrice)
           {
            sweepFound = true;
            sweepStrength = MathMax(0.0, MathMin(((poolPrice - cd.low) / barATR) / 0.5, 1.0));
            sweepBarIdx = i;
            break;
           }
        }
      else
        {
         if(cd.high > poolPrice && cd.close < poolPrice)
           {
            sweepFound = true;
            sweepStrength = MathMax(0.0, MathMin(((cd.high - poolPrice) / barATR) / 0.5, 1.0));
            sweepBarIdx = i;
            break;
           }
        }
     }
   r.sweepFound = sweepFound;
   r.sweepScore = sweepFound ? 25.0 : 0.0;
   if(!sweepFound)
     {
      r.reason = "Internal structure present, but liquidity was never swept — no inducement, no trade";
      return r;
     }

   // Confirming minor BOS: after the sweep, price must close back beyond
   // the opposing minor swing formed during the pullback (a small
   // structure break confirming the reversal continues with the impulse).
   double minorOpp = forBuy ? -DBL_MAX : DBL_MAX;
   for(int i = sweepBarIdx; i <= pullbackTo; i++)
     {
      if(!FindMinorSwing(i, forBuy)) continue; // forBuy -> looking for a minor HIGH to break above
      double p = forBuy ? m_candles.GetCandle(i).high : m_candles.GetCandle(i).low;
      if(forBuy && p > minorOpp) minorOpp = p;
      if(!forBuy && p < minorOpp) minorOpp = p;
     }
   bool bosConfirmed = false;
   if((forBuy && minorOpp > -DBL_MAX) || (!forBuy && minorOpp < DBL_MAX))
     {
      for(int i = sweepBarIdx - 1; i >= 0; i--)
        {
         CandleData cd = m_candles.GetCandle(i);
         if(forBuy && cd.close > minorOpp) { bosConfirmed = true; break; }
         if(!forBuy && cd.close < minorOpp) { bosConfirmed = true; break; }
        }
     }
   r.bosConfirmed = bosConfirmed;
   r.bosScore = bosConfirmed ? 20.0 : 0.0;
   if(!bosConfirmed)
     {
      r.reason = "Liquidity swept, but no confirming minor BOS yet — wait for structure to break";
      return r;
     }

   r.valid = true;
   r.leg = leg;
   r.totalScore = r.impulseScore + r.structureScore + r.sweepScore + r.bosScore;
   r.reason = "Inducement sequence confirmed: impulse -> pullback structure -> sweep -> minor BOS";
   return r;
  }
#endif
//+------------------------------------------------------------------+
