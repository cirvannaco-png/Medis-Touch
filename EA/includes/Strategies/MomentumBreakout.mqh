//+------------------------------------------------------------------+
//|                                 Strategies/MomentumBreakout.mqh   |
//+------------------------------------------------------------------+
#ifndef MOMENTUMBREAKOUT_MQH
#define MOMENTUMBREAKOUT_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../Structure/BOS.mqh"
#include "../SmartMoney/Liquidity.mqh"
#include "../Analysis/VolatilityRegime.mqh"

// v2.12 addition. Strategy module #1 of the multi-strategy architecture
// (see docs/CHANGELOG.md v2.12 entry) — Mean Reversion and the Key-Level
// Price Action engine are next, not built yet. Deliberately reuses
// existing primitives instead of reimplementing them:
//   - CBOS already stores BOSEvent.strength (0-1, displacement/ATR +
//     volume ratio composite) and BOSEvent.bar_index (recency) per
//     event — that IS the "genuine displacement? volume abnormal?"
//     read the spec asked for, computed once by CBOS::Detect() and
//     reused here rather than recomputed.
//   - CLiquidity's own event list is reused to detect the overlap case
//     ("liquidity breakout... interesting because it overlaps with your
//     SMC engine") rather than guessing at a second sweep detector.
//
// CLASSIFICATION (BREAKOUT_*, see Core/Config.mqh for definitions):
//   FAILED     : checked first — price already closed back on the wrong
//                side of the broken level. Whatever else was true about
//                the break, it didn't hold, so this overrides every
//                other label.
//   LIQUIDITY  : the BOS bar coincides (within m_liqOverlapBars) with a
//                liquidity-sweep event. Checked before EXPANSION/
//                EXHAUSTION because a sweep-driven break and a pure
//                displacement break are different setups even when the
//                raw strength score looks similar.
//   EXHAUSTION : price was already extended (pre-break run measured over
//                m_extensionLookbackBars, in ATR) beyond m_exhaustionATR
//                BEFORE the break bar — a strong strength score here is
//                the doc's warning case ("do not chase"), not a green
//                light.
//   EXPANSION  : none of the above — fresh, displacement-and-volume-
//                backed, not already extended, not sweep-driven.
//   NONE       : no BOS in the setup direction within m_recencyBars.
//
// MOMENTUM SCORE is a separate, simpler read from BREAKOUT SCORE: net
// directional close-to-close movement over m_momentumLookbackBars,
// scaled by that window's own average ATR. This is a plain rate-of-
// change-over-volatility heuristic, not a proprietary momentum
// indicator — stated plainly per this codebase's convention of not
// overclaiming what a heuristic proves (see MarketPhase.mqh's own
// caveat for the precedent).
//
// DIAGNOSTIC ONLY. See Regime/RegimeDetector.mqh's header for the same
// disclosure: nothing here feeds CalculateConfidence(), CDecisionEngine,
// or order sizing. Read only by CSV logging today.
class CMomentumBreakoutEngine
  {
private:
   CCandleData*         m_candles;
   CBOS*                m_bos;
   CLiquidity*          m_liquidity;
   CVolatilityRegime*   m_volRegime;

   int                  m_recencyBars;            // how far back a BOS still counts as "recent" (default 10)
   int                  m_liqOverlapBars;          // BOS/liquidity bar_index gap allowed to call it LIQUIDITY (default 2)
   int                  m_extensionLookbackBars;   // window checked BEFORE the break bar for pre-existing extension (default 15)
   double               m_exhaustionATRMult;       // pre-break run, in ATR, above which a break counts as EXHAUSTION (default 3.0)
   int                  m_momentumLookbackBars;    // window for the momentum score (default 10)

   bool                 FindRecentBOS(bool forBuy, BOSEvent &out);
   bool                 HasNearbyLiquidityEvent(int barIndex);
   bool                 ClosedBackAcross(const BOSEvent &ev, bool forBuy);
   double               PreBreakExtensionATR(int barIndex, bool forBuy);

public:
                        CMomentumBreakoutEngine() : m_candles(NULL), m_bos(NULL), m_liquidity(NULL), m_volRegime(NULL),
                                                     m_recencyBars(10), m_liqOverlapBars(2),
                                                     m_extensionLookbackBars(15), m_exhaustionATRMult(3.0),
                                                     m_momentumLookbackBars(10) {}
   void                 Init(CCandleData* candles, CBOS* bos, CLiquidity* liquidity, CVolatilityRegime* volRegime)
     {
      m_candles = candles;
      m_bos = bos;
      m_liquidity = liquidity;
      m_volRegime = volRegime;
     }
   // All defaults above are starting points, not tuned constants — same
   // discipline note as every other Configure*() in this codebase
   // (e.g. CScoringEngine::ConfigureLearnedDiagnostics).
   void                 Configure(int recencyBars = 10, int liqOverlapBars = 2,
                                   int extensionLookbackBars = 15, double exhaustionATRMult = 3.0,
                                   int momentumLookbackBars = 10)
     {
      m_recencyBars = MathMax(1, recencyBars);
      m_liqOverlapBars = MathMax(0, liqOverlapBars);
      m_extensionLookbackBars = MathMax(1, extensionLookbackBars);
      m_exhaustionATRMult = (exhaustionATRMult > 0) ? exhaustionATRMult : 3.0;
      m_momentumLookbackBars = MathMax(1, momentumLookbackBars);
     }

   void                 Evaluate(bool forBuy, double &momentumScore, double &breakoutScore, ENUM_BREAKOUT_CLASS &breakoutClass);
  };
//+------------------------------------------------------------------+
// Scans most-recent-first for the first BOS event whose direction
// matches forBuy and whose bar_index is within m_recencyBars. GetBOS(0)
// alone isn't enough — the single most recent BOS overall may be in the
// OPPOSITE direction to the setup being evaluated.
bool CMomentumBreakoutEngine::FindRecentBOS(bool forBuy, BOSEvent &out)
  {
   if(m_bos == NULL) return false;
   int n = m_bos.Count();
   for(int i = 0; i < n; i++)
     {
      BOSEvent ev = m_bos.GetBOS(i);
      if(ev.bar_index > m_recencyBars) break; // events are stored most-recent-first; once we're past the window, nothing later helps
      if(ev.is_bullish == forBuy)
        {
         out = ev;
         return true;
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
bool CMomentumBreakoutEngine::HasNearbyLiquidityEvent(int barIndex)
  {
   if(m_liquidity == NULL) return false;
   int n = m_liquidity.EventCount();
   for(int i = 0; i < n; i++)
     {
      LiquidityEvent ev = m_liquidity.GetEvent(i);
      if(MathAbs(ev.bar_index - barIndex) <= m_liqOverlapBars)
         return true;
      if(ev.bar_index - barIndex > m_liqOverlapBars + m_recencyBars) break; // sorted most-recent-first; far enough away we can stop
     }
   return false;
  }
//+------------------------------------------------------------------+
// Has price, since the break, closed back on the WRONG side of the
// level that was broken? ev.price is the level; a bullish BOS failing
// means a later (more recent, lower shift) candle closed back below it.
bool CMomentumBreakoutEngine::ClosedBackAcross(const BOSEvent &ev, bool forBuy)
  {
   if(m_candles == NULL) return false;
   for(int shift = 0; shift < ev.bar_index; shift++)
     {
      CandleData cd = m_candles.GetCandle(shift);
      if(forBuy && cd.close < ev.price) return true;
      if(!forBuy && cd.close > ev.price) return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
// How far, in ATR, price had already moved in the setup's direction
// over the m_extensionLookbackBars BEFORE the break bar — i.e. was the
// move already extended before this breakout even happened.
double CMomentumBreakoutEngine::PreBreakExtensionATR(int barIndex, bool forBuy)
  {
   if(m_candles == NULL) return 0.0;
   int startShift = barIndex + 1;
   int endShift = barIndex + m_extensionLookbackBars;
   if(endShift >= m_candles.Total()) endShift = m_candles.Total() - 1;
   if(startShift >= endShift) return 0.0;

   double atr = m_candles.GetATR(barIndex);
   if(atr <= 0) return 0.0;

   CandleData startCd = m_candles.GetCandle(endShift);   // older
   CandleData endCd   = m_candles.GetCandle(startShift); // just before the break
   double move = forBuy ? (endCd.close - startCd.close) : (startCd.close - endCd.close);
   return move / atr; // negative if price moved the "wrong" way before the break — not extended
  }
//+------------------------------------------------------------------+
void CMomentumBreakoutEngine::Evaluate(bool forBuy, double &momentumScore, double &breakoutScore, ENUM_BREAKOUT_CLASS &breakoutClass)
  {
   momentumScore = 0.0;
   breakoutScore = 0.0;
   breakoutClass = BREAKOUT_NONE;

   // --- momentum score: independent of whether a BOS exists at all ---
   if(m_candles != NULL && m_candles.Total() > m_momentumLookbackBars + 1)
     {
      double sumAtr = 0.0;
      int atrCount = 0;
      for(int i = 0; i < m_momentumLookbackBars; i++)
        {
         double a = m_candles.GetATR(i);
         if(a > 0) { sumAtr += a; atrCount++; }
        }
      if(atrCount > 0)
        {
         double avgAtr = sumAtr / atrCount;
         CandleData now = m_candles.GetCandle(0);
         CandleData then = m_candles.GetCandle(m_momentumLookbackBars);
         double netMove = forBuy ? (now.close - then.close) : (then.close - now.close);
         double raw = netMove / (avgAtr * m_momentumLookbackBars * 0.35); // 0.35 = expected fraction of ATR moved per bar in a genuine trend; empirical starting point, not fit
         momentumScore = MathMax(0.0, MathMin(raw * 100.0, 100.0));
        }
     }

   // --- breakout classification: requires a recent BOS in this direction ---
   BOSEvent ev;
   if(!FindRecentBOS(forBuy, ev))
      return; // stays BREAKOUT_NONE / breakoutScore 0.0

   breakoutScore = MathMax(0.0, MathMin(ev.strength * 100.0, 100.0));

   if(ClosedBackAcross(ev, forBuy))
     {
      breakoutClass = BREAKOUT_FAILED;
      return;
     }
   if(HasNearbyLiquidityEvent(ev.bar_index))
     {
      breakoutClass = BREAKOUT_LIQUIDITY;
      return;
     }
   if(PreBreakExtensionATR(ev.bar_index, forBuy) >= m_exhaustionATRMult)
     {
      breakoutClass = BREAKOUT_EXHAUSTION;
      return;
     }
   breakoutClass = BREAKOUT_EXPANSION;
  }
#endif
//+------------------------------------------------------------------+
