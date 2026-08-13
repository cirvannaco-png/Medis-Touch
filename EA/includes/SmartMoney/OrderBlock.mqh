//+------------------------------------------------------------------+
//|                                         SmartMoney/OrderBlock.mqh |
//+------------------------------------------------------------------+
#ifndef ORDERBLOCK_MQH
#define ORDERBLOCK_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../Structure/BOS.mqh"

// v2.8 addition, closing the gap flagged in the pre-rewrite audit: the
// codebase had Inducement/FVG/Liquidity/SR confluence but nothing reading
// Order Blocks on a higher timeframe, even though the point-table spec's
// "HTF Alignment" bucket implicitly assumes one. This engine is meant to
// run on an HTF CTFContext (H4/D1) separate from the entry-timeframe FVG
// context — same "own candle series per timeframe" discipline as
// CTFContext itself.
//
// Definition used (standard SMC OB, not a proprietary variant):
//   Bullish OB = the last down-close candle immediately before a
//                displacement leg that breaks structure upward.
//   Bearish OB = the last up-close candle immediately before a
//                displacement leg that breaks structure downward.
// Zone = candle's [open, low] for a bullish OB, [open, high] for a
// bearish OB — the body-to-wick-extreme range, which is where the
// original imbalance/inefficiency actually sits, not the full [high,low]
// wick range (that overstates the zone and generates false confluence).
class COrderBlock
  {
private:
   CCandleData*      m_candles;
   OrderBlockZone     m_zones[];
   int                m_zoneCount;
   double             m_displacementATRMult;   // min range/ATR to count as a displacement leg
   double             m_minBodyRatio;          // min body/range of the displacement candle
   int                m_maxZones;              // cap so old HTF zones don't accumulate forever

   bool              IsDisplacement(int idx, bool &bullish);
   // FIX (audit #18): checks whether a genuine, chronologically-confirmed
   // BOS event (from the already-fixed CBOS engine — see Structure/BOS.mqh)
   // exists at or near this candle, in the matching direction.
   bool              CoincidesWithStructureBreak(int idx, bool bullish);
   void              UpdateState(OrderBlockZone &z);
   CBOS*             m_bos;

public:
                     COrderBlock();
   void              Init(CCandleData* candleData, CBOS* bos, double displacementATRMult = 1.5,
                          double minBodyRatio = 0.5, int maxZones = 15);
   void              Detect();
   void              UpdateAllStates();
   int               Count() const { return m_zoneCount; }
   OrderBlockZone     GetZone(int i) const; // 0 = most recent
   // Nearest fresh/tested zone in `dir` within distATRMax of price; returns
   // false if none. Used by Scoring::ObScore()/ObGate().
   bool              NearestZone(ENUM_FVG_DIR dir, double price, double atr, double distATRMax, OrderBlockZone &out);
  };
//+------------------------------------------------------------------+
COrderBlock::COrderBlock() : m_candles(NULL), m_bos(NULL), m_zoneCount(0), m_displacementATRMult(1.5),
                              m_minBodyRatio(0.5), m_maxZones(15) {}
//+------------------------------------------------------------------+
void COrderBlock::Init(CCandleData* candleData, CBOS* bos, double displacementATRMult, double minBodyRatio, int maxZones)
  {
   m_candles = candleData;
   m_bos = bos;
   m_displacementATRMult = displacementATRMult;
   m_minBodyRatio = minBodyRatio;
   m_maxZones = MathMax(3, maxZones);
  }
//+------------------------------------------------------------------+
bool COrderBlock::IsDisplacement(int idx, bool &bullish)
  {
   if(m_candles == NULL) return false;
   CandleData cd = m_candles.GetCandle(idx);
   double atr = cd.atr;
   if(atr <= 0) return false;
   double range = cd.high - cd.low;
   if(range <= 0) return false;
   double body = MathAbs(cd.close - cd.open);
   if(range / atr < m_displacementATRMult) return false;
   if(body / range < m_minBodyRatio) return false;
   bullish = (cd.close > cd.open);
   return true;
  }
//+------------------------------------------------------------------+
// FIX (audit #18): "large directional candle" alone was standing in for
// "order block confirmed by displacement + structure break" — the docstring
// at the top of this file promised the latter but IsDisplacement() only
// ever checked the former (range/ATR, body/range, direction). A large
// candle in the middle of a trading range with no structure broken is not
// an institutional order block by any SMC definition; it's just a big
// candle. This cross-checks against CBOS's already-corrected, non-
// lookahead event list: a real BOS event of the matching direction must
// exist within a small tolerance of this bar for the displacement to
// count as genuine. Tolerance of 2 bars covers the close that actually
// triggers the BOS landing 1-2 bars after the visually "big" candle
// starts the move (common when displacement spans multiple candles).
bool COrderBlock::CoincidesWithStructureBreak(int idx, bool bullish)
  {
   if(m_bos == NULL) return true; // no BOS engine wired in — fail open rather than silently disabling OB detection entirely
   int n = m_bos.Count();
   for(int i = 0; i < n; i++)
     {
      BOSEvent ev = m_bos.GetBOS(i);
      if(ev.is_bullish != bullish) continue;
      if(MathAbs(ev.bar_index - idx) <= 2) return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
// Series-indexed like FVG.mqh: shift 0 = current bar, i grows toward the
// past. For a displacement at idx, the "last opposite-close candle before
// it" is walked backward from idx+1 (older bars) until a candle whose
// close/open sign is opposite the displacement direction is found. This
// mirrors the standard SMC OB definition rather than blindly taking
// idx+1, which would misfire whenever two displacement-direction candles
// print back to back.
void COrderBlock::Detect()
  {
   m_zoneCount = 0;
   if(m_candles == NULL) return;
   ArrayFree(m_zones);
   int total = m_candles.Total();
   if(total < 5) return;

   int lookback = MathMin(total - 2, 300); // HTF context, doesn't need the full buffer
   for(int i = 1; i < lookback && m_zoneCount < m_maxZones; i++)
     {
      bool dispBullish;
      if(!IsDisplacement(i, dispBullish)) continue;
      if(!CoincidesWithStructureBreak(i, dispBullish)) continue; // FIX #18: displacement alone isn't enough

      // walk backward (older bars) from the displacement candle for the
      // nearest candle of the opposite close direction, within 5 bars —
      // beyond that it's no longer "the" originating candle.
      for(int j = i + 1; j < MathMin(i + 6, total); j++)
        {
         CandleData ob = m_candles.GetCandle(j);
         bool obUp = (ob.close > ob.open);
         if(dispBullish && obUp) continue;       // want a DOWN candle before a bullish leg
         if(!dispBullish && !obUp) continue;      // want an UP candle before a bearish leg

         OrderBlockZone z;
         ZeroMemory(z);
         z.time = ob.time;
         z.bar_index = j;
         z.dir = dispBullish ? FVG_BULL : FVG_BEAR;
         z.state = OB_FRESH;
         z.displacement_atr = (m_candles.GetCandle(i).high - m_candles.GetCandle(i).low) / m_candles.GetCandle(i).atr;
         if(dispBullish) { z.top = ob.open; z.bottom = ob.low; }
         else             { z.top = ob.high; z.bottom = ob.open; }
         if(z.top < z.bottom) { double t = z.top; z.top = z.bottom; z.bottom = t; }

         UpdateState(z);
         if(z.state != OB_MITIGATED)
           {
            int n = ArraySize(m_zones);
            ArrayResize(m_zones, n + 1);
            m_zones[n] = z;
            m_zoneCount++;
           }
         break; // only the nearest opposite-close candle counts as THE origin
        }
     }
  }
//+------------------------------------------------------------------+
// Re-derives state by replaying candles newer than the zone (bar_index-1
// down to 0) against its top/bottom — same touched/mitigated logic FVG
// uses, kept local here since OB mitigation rule differs slightly (a
// CLOSE through the far edge invalidates; a wick-only touch just tests).
void COrderBlock::UpdateState(OrderBlockZone &z)
  {
   if(m_candles == NULL) return;
   bool bullish = (z.dir == FVG_BULL);
   for(int k = z.bar_index - 1; k >= 0; k--)
     {
      CandleData cd = m_candles.GetCandle(k);
      bool touched = (cd.low <= z.top && cd.high >= z.bottom);
      if(!touched) continue;
      bool closedThrough = bullish ? (cd.close < z.bottom) : (cd.close > z.top);
      if(closedThrough) { z.state = OB_MITIGATED; return; }
      if(z.state == OB_FRESH) z.state = OB_TESTED;
     }
  }
//+------------------------------------------------------------------+
void COrderBlock::UpdateAllStates()
  {
   for(int i = 0; i < m_zoneCount; i++)
      UpdateState(m_zones[i]);
  }
//+------------------------------------------------------------------+
OrderBlockZone COrderBlock::GetZone(int i) const
  {
   OrderBlockZone empty;
   ZeroMemory(empty);
   if(i < 0 || i >= m_zoneCount) return empty;
   // m_zones is filled oldest-displacement-first per outer loop order
   // (i ascends = older); present most-recent-first to match every other
   // engine's GetZone(0)==newest convention.
   return m_zones[m_zoneCount - 1 - i];
  }
//+------------------------------------------------------------------+
bool COrderBlock::NearestZone(ENUM_FVG_DIR dir, double price, double atr, double distATRMax, OrderBlockZone &out)
  {
   if(atr <= 0) return false;
   double bestDist = -1.0;
   for(int i = 0; i < m_zoneCount; i++)
     {
      OrderBlockZone z = GetZone(i);
      if(z.dir != dir) continue;
      if(z.state == OB_MITIGATED) continue;
      double mid = (z.top + z.bottom) / 2.0;
      double dist = MathAbs(price - mid) / atr;
      if(dist > distATRMax) continue;
      if(bestDist < 0 || dist < bestDist) { bestDist = dist; out = z; }
     }
   return bestDist >= 0;
  }
#endif
//+------------------------------------------------------------------+
