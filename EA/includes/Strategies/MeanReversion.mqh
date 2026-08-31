//+------------------------------------------------------------------+
//|                                    Strategies/MeanReversion.mqh   |
//+------------------------------------------------------------------+
#ifndef MEANREVERSION_MQH
#define MEANREVERSION_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../SmartMoney/SupportResistance.mqh"
#include "../SmartMoney/ValueAreaEngine.mqh"
#include "../SmartMoney/Liquidity.mqh"
#include "../Structure/BOS.mqh"
#include "../Analysis/VolatilityRegime.mqh"

// v2.13 addition. Strategy module #2 of the multi-strategy architecture
// (see Strategies/MomentumBreakout.mqh for module #1 and the same
// rationale for building one module at a time). Reuses existing
// primitives rather than reimplementing them:
//   - CValueAreaEngine.VAH()/VAL()   -> "statistically stretched price"
//   - CSupportResistance zones       -> "rejection at established level"
//   - CLiquidity's event list        -> "liquidity sweep"
//   - CBOS's stored BOSEvent.strength -> "declining momentum" read,
//     inverted: a STRONG opposing BOS means momentum is NOT declining,
//     which is this module's trend-conflict override.
//
// TWO QUALIFYING PATHS, not one bar:
//   VALUE_FADE       : price stretched beyond a value-area edge by at
//                      least m_minStretchATR, AND (a rejection wick OR
//                      a confirming liquidity sweep). The stronger path
//                      — the doc's primary case.
//   LEVEL_REJECTION  : price at a plain SR zone with a rejection wick,
//                      with no value-area stretch requirement. The
//                      weaker path — still a real setup, scored lower.
//   NONE             : neither path's minimum bar (wick OR SR touch) is
//                      met at all.
//   TREND_CONFLICT   : OVERRIDES either path above. A recent BOS in the
//                      direction the stretch is already moving (i.e.
//                      AGAINST the proposed fade) with strength at or
//                      above m_trendConflictMinStrength means the move
//                      being faded is still structurally confirmed.
//                      Per the doc: "mean reversion should not fight a
//                      strong trend merely because price looks
//                      expensive." The classification changes; the
//                      underlying reversion_score is left as computed
//                      rather than zeroed, so the CSV still shows "this
//                      looked like a fade, and here's why it's flagged
//                      risky" instead of erasing the read.
//
// TIMEFRAME NOTE (same disclosure as MomentumBreakout.mqh): candles/SR/
// value-area here are the chart-TF context (m_srCtx), so ATR and price
// distance are self-consistent. The liquidity and BOS pointers this
// class takes may belong to DIFFERENT timeframes if the EA is
// configured that way (InpLiquidityTF / InpBOSTF) — the same
// cross-timeframe caveat MomentumBreakout.mqh already carries, not a
// new one introduced here.
//
// "CONTROLLED VOLATILITY": the doc lists this as a qualifying condition,
// not just a bonus. Implemented as a simple gate — VOL_REGIME_HIGH
// suppresses the score's volatility component to 0 rather than
// disqualifying the setup outright, since a single percentile read
// shouldn't unilaterally veto a setup that's otherwise well-formed;
// scoring it low still lets it show up as a weak signal in the CSV
// rather than disappearing.
//
// DIAGNOSTIC ONLY. Same as every other v2.1x addition: nothing here
// feeds CalculateConfidence(), CDecisionEngine, or order sizing.
class CMeanReversionEngine
  {
private:
   CCandleData*         m_candles;      // chart-TF (m_srCtx.candles) — same context as m_sr/m_valueArea
   CSupportResistance*  m_sr;           // chart-TF SR zones
   CValueAreaEngine*    m_valueArea;    // chart-TF POC/VAH/VAL
   CLiquidity*          m_liquidity;    // see timeframe note above
   CVolatilityRegime*   m_volRegime;    // chart-TF instance — see Analysis/Scoring.mqh wiring note (deliberately separate from the BOS-TF instance Momentum/Regime use)
   CBOS*                m_opposingBos;  // see timeframe note above

   double               m_minStretchATR;            // VA-edge stretch, in ATR, required for the VALUE_FADE path (default 1.0)
   double               m_srZoneATRTolerance;        // how close price must be to an SR zone edge, in ATR, to count as "at" it (default 0.25)
   double               m_wickRejectionRatio;        // wick length / total range required to call a candle a rejection (default 0.55)
   int                  m_liqRecencyBars;            // how far back a sweep still counts as confirmation (default 10)
   int                  m_trendConflictRecencyBars;  // how far back an opposing BOS still counts as live conflict (default 10)
   double               m_trendConflictMinStrength;  // BOSEvent.strength (0-1) threshold to call it a real conflict (default 0.5)

   bool                 HasNearbySRZone(double price, double atr, bool forBuy);
   bool                 RejectionWickPresent(bool forBuy);
   bool                 HasRecentOpposingSweep(bool forBuy);
   bool                 HasTrendConflict(bool forBuy);

public:
                        CMeanReversionEngine() : m_candles(NULL), m_sr(NULL), m_valueArea(NULL), m_liquidity(NULL),
                                                  m_volRegime(NULL), m_opposingBos(NULL),
                                                  m_minStretchATR(1.0), m_srZoneATRTolerance(0.25),
                                                  m_wickRejectionRatio(0.55), m_liqRecencyBars(10),
                                                  m_trendConflictRecencyBars(10), m_trendConflictMinStrength(0.5) {}
   void                 Init(CCandleData* candles, CSupportResistance* sr, CValueAreaEngine* valueArea,
                              CLiquidity* liquidity, CVolatilityRegime* volRegime, CBOS* opposingBos)
     {
      m_candles = candles;
      m_sr = sr;
      m_valueArea = valueArea;
      m_liquidity = liquidity;
      m_volRegime = volRegime;
      m_opposingBos = opposingBos;
     }
   // Defaults are starting points from the spec's own reasoning, not
   // tuned constants — same discipline note as every other Configure()
   // in this codebase.
   void                 Configure(double minStretchATR = 1.0, double srZoneATRTolerance = 0.25,
                                   double wickRejectionRatio = 0.55, int liqRecencyBars = 10,
                                   int trendConflictRecencyBars = 10, double trendConflictMinStrength = 0.5)
     {
      m_minStretchATR = (minStretchATR > 0) ? minStretchATR : 1.0;
      m_srZoneATRTolerance = (srZoneATRTolerance >= 0) ? srZoneATRTolerance : 0.25;
      m_wickRejectionRatio = (wickRejectionRatio > 0 && wickRejectionRatio <= 1.0) ? wickRejectionRatio : 0.55;
      m_liqRecencyBars = MathMax(0, liqRecencyBars);
      m_trendConflictRecencyBars = MathMax(0, trendConflictRecencyBars);
      m_trendConflictMinStrength = (trendConflictMinStrength >= 0 && trendConflictMinStrength <= 1.0) ? trendConflictMinStrength : 0.5;
     }

   void                 Evaluate(bool forBuy, double &reversionScore, ENUM_REVERSION_CLASS &reversionClass);
  };
//+------------------------------------------------------------------+
// forBuy -> looking for a support zone AT/BELOW price (fading a downside
// stretch, expecting a bounce up). !forBuy -> resistance zone AT/ABOVE
// price. Price sitting inside a zone counts as "at" it (distance clamped
// to 0), same convention as the ATR-tolerance checks elsewhere in this
// codebase (e.g. OBScore's distance-to-zero-at-max decay).
bool CMeanReversionEngine::HasNearbySRZone(double price, double atr, bool forBuy)
  {
   if(m_sr == NULL) return false;
   int n = m_sr.Count();
   for(int i = 0; i < n; i++)
     {
      SRZone z = m_sr.GetZone(i);
      double dist = forBuy ? (price - z.top) : (z.bottom - price);
      if(dist < 0) dist = 0.0;
      if(dist <= atr * m_srZoneATRTolerance)
         return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
// Checked on shift 1 (the last fully CLOSED bar), not shift 0 — same
// "final, not still-forming" convention Scoring.mqh's RVOL check uses
// (see FIX #16 there): a wick on the still-printing bar can still grow
// or vanish, so it isn't yet evidence of anything.
bool CMeanReversionEngine::RejectionWickPresent(bool forBuy)
  {
   if(m_candles == NULL || m_candles.Total() < 2) return false;
   CandleData cd = m_candles.GetCandle(1);
   double range = cd.high - cd.low;
   if(range <= 0) return false;
   double lowerWick = MathMin(cd.open, cd.close) - cd.low;
   double upperWick = cd.high - MathMax(cd.open, cd.close);
   return forBuy ? ((lowerWick / range) >= m_wickRejectionRatio)
                 : ((upperWick / range) >= m_wickRejectionRatio);
  }
//+------------------------------------------------------------------+
// forBuy (fading a downside stretch) wants confirmation via a SELL-SIDE
// sweep (stops taken beneath the lows before the bounce); the bearish
// mirror wants a BUY-SIDE sweep.
bool CMeanReversionEngine::HasRecentOpposingSweep(bool forBuy)
  {
   if(m_liquidity == NULL) return false;
   ENUM_LIQ_TYPE target = forBuy ? LIQ_SELL_SIDE : LIQ_BUY_SIDE;
   int n = m_liquidity.EventCount();
   for(int i = 0; i < n; i++)
     {
      LiquidityEvent ev = m_liquidity.GetEvent(i);
      if(ev.bar_index > m_liqRecencyBars) break; // most-recent-first; nothing further back helps
      if(ev.type == target && ev.swept)
         return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
// A recent BOS in the direction the stretch is ALREADY moving (i.e.
// against the proposed fade) — is_bullish == !forBuy, since forBuy fades
// a bearish move and !forBuy fades a bullish one.
bool CMeanReversionEngine::HasTrendConflict(bool forBuy)
  {
   if(m_opposingBos == NULL) return false;
   int n = m_opposingBos.Count();
   for(int i = 0; i < n; i++)
     {
      BOSEvent ev = m_opposingBos.GetBOS(i);
      if(ev.bar_index > m_trendConflictRecencyBars) break; // most-recent-first
      if(ev.is_bullish == !forBuy && ev.strength >= m_trendConflictMinStrength)
         return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
void CMeanReversionEngine::Evaluate(bool forBuy, double &reversionScore, ENUM_REVERSION_CLASS &reversionClass)
  {
   reversionScore = 0.0;
   reversionClass = REVERSION_NONE;

   if(m_candles == NULL || m_candles.Total() < 2) return;
   double price = m_candles.GetCandle(0).close; // live/current-bar proxy, same convention MomentumBreakout.mqh uses
   double atr = m_candles.GetATR(0);
   if(atr <= 0) return;

   bool wickRejection = RejectionWickPresent(forBuy);
   bool srNear = HasNearbySRZone(price, atr, forBuy);

   // Neither qualifying bar is met at all — stay NONE rather than guess.
   if(!wickRejection && !srNear)
      return;

   bool volControlled = true; // fail OPEN here deliberately: an unavailable vol read shouldn't zero out an otherwise-scored setup, unlike the hard fail-closed on ATR<=0 above where the whole score is meaningless without it
   if(m_volRegime != NULL)
      volControlled = (m_volRegime.Classify(0) != VOL_REGIME_HIGH);

   double stretchATR = 0.0;
   bool vaStretched = false;
   if(m_valueArea != NULL && m_valueArea.IsValid())
     {
      stretchATR = forBuy ? (m_valueArea.VAL() - price) / atr : (price - m_valueArea.VAH()) / atr;
      vaStretched = (stretchATR >= m_minStretchATR);
     }

   bool sweepConfirmed = HasRecentOpposingSweep(forBuy);
   double score = 0.0;

   if(vaStretched)
     {
      score += MathMin(stretchATR / 3.0, 1.0) * 40.0; // stretch component, capped at 3 ATR beyond the VA edge
      if(wickRejection)   score += 25.0;
      if(sweepConfirmed)  score += 20.0;
      if(volControlled)   score += 15.0;
      reversionClass = REVERSION_VALUE_FADE;
     }
   else if(srNear)
     {
      if(wickRejection)   score += 35.0;
      if(sweepConfirmed)  score += 25.0;
      if(volControlled)   score += 15.0;
      reversionClass = REVERSION_LEVEL_REJECTION;
     }
   else
      return; // guarded above, kept here as an explicit fail-closed rather than falling through silently

   reversionScore = MathMax(0.0, MathMin(score, 100.0));

   if(HasTrendConflict(forBuy))
      reversionClass = REVERSION_TREND_CONFLICT; // score left as-is, see file header
  }
#endif
//+------------------------------------------------------------------+
