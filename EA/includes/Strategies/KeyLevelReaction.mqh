//+------------------------------------------------------------------+
//|                                 Strategies/KeyLevelReaction.mqh   |
//+------------------------------------------------------------------+
#ifndef KEYLEVELREACTION_MQH
#define KEYLEVELREACTION_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../Core/SessionFilter.mqh"
#include "../SmartMoney/SupportResistance.mqh"
#include "../SmartMoney/ValueAreaEngine.mqh"
#include "../SmartMoney/Liquidity.mqh"
#include "../SmartMoney/OrderBlock.mqh"
#include "../SmartMoney/ExtendedKeyLevels.mqh"

// v2.14 addition. Strategy module #3 of the multi-strategy architecture
// (see MomentumBreakout.mqh for module #1 and MeanReversion.mqh for
// module #2, and the shared "one module at a time" rationale). This is
// the doc's "Key-Level Reaction Engine": identify a level, then
// classify what price actually did there as structured data, instead
// of a discretionary "bearish engulfing candle" read.
//
// LEVEL SOURCES (ENUM_KEYLEVEL_SOURCE) — reused, not reinvented:
//   LEVEL_SR             : CSupportResistance zones (swing-based, chart TF)
//   LEVEL_ORDER_BLOCK     : COrderBlock zones (chart-TF instance — see
//                          the timeframe note below for why NOT the
//                          separate genuinely-HTF instance OBScore()
//                          uses)
//   LEVEL_VALUE_AREA      : CValueAreaEngine's POC/VAH/VAL
//   LEVEL_LIQUIDITY_POOL  : CLiquidity events flagged `external` — per
//                          that struct's own comment, "external = true
//                          = D1 high/low sweep", which IS the doc's
//                          "previous day high/low" entry, reused
//                          directly rather than recomputed.
//   LEVEL_PREV_WEEK       : CExtendedKeyLevels — previous week's high/low
//                          (v2.17, see that file's header)
//   LEVEL_SESSION         : CExtendedKeyLevels — current session's
//                          high/low so far (v2.17)
//   LEVEL_PSYCHOLOGICAL   : CExtendedKeyLevels — nearest round-number
//                          level (v2.17)
// v2.17: the three sources below are now wired in — see
// SmartMoney/ExtendedKeyLevels.mqh's header for why they were held back
// from the original v2.14 pass and built as their own pass instead.
//
// Of every candidate level across the four sources above, the NEAREST
// one to current price (within m_levelSearchATRMax) is picked — no
// source-type priority weighting. "Nearest, no favorites" is a
// deliberate, simple rule, not a gap.
//
// REACTION CLASSIFICATION (ENUM_KEYLEVEL_REACTION) — examines the last
// m_lookbackBars CLOSED bars (shift 1..N) relative to the chosen
// level's price, using "hold side" (the side price approached the
// level from, matching the setup's forBuy direction) and "far side"
// (the other side) rather than absolute up/down, so one classifier
// works for a support-side read and a resistance-side read alike:
//   ACCEPTANCE   : two or more of the most recent closes are on the far
//                  side — the level has flipped role, not just been
//                  poked at.
//   BREAK        : only the single most recent close is on the far
//                  side — fresh, unconfirmed by a second close.
//   RETEST       : price broke to the far side within the lookback
//                  window, has since come back, and is now sitting at
//                  the level again without having closed back past it.
//   FAILED_BREAK : price broke to the far side within the lookback
//                  window, then closed back on the hold side — the
//                  break didn't hold.
//   REJECTION    : price touched the level (candle range include it)
//                  but closed on the hold side with a rejection wick
//                  through the level.
//   ABSORPTION   : the level was touched at least m_absorptionMinTouches
//                  times in the window with no break and no strong
//                  rejection wick — repeated testing without resolving
//                  either way.
//   NONE         : no level within range, or a level was found but none
//                  of the above patterns fit.
//
// HONEST LIMIT ON THE SCORE: unlike MomentumBreakout's/MeanReversion's
// continuously computed 0-100 scores, `reaction_score` here is a FIXED
// per-classification conviction weight, not a composite calculated from
// multiple factors. The underlying signal this module produces is
// fundamentally categorical ("what happened"), and forcing a fake
// continuous score onto it to look consistent with the other two
// modules would misrepresent what's actually being measured.
//
// TIMEFRAME NOTE: candles/SR/value-area/order-block here are all the
// CHART-TF context (m_srCtx) — self-consistent. Liquidity reuses
// whichever timeframe InpLiquidityTF is configured to, same
// cross-timeframe caveat MomentumBreakout.mqh and MeanReversion.mqh
// already carry.
//
// DIAGNOSTIC ONLY, same as every v2.1x addition before it.
class CKeyLevelEngine
  {
private:
   CCandleData*         m_candles;
   CSupportResistance*  m_sr;
   CValueAreaEngine*    m_valueArea;
   CLiquidity*          m_liquidity;
   COrderBlock*         m_orderBlock;
   CExtendedKeyLevels*  m_extLevels;    // v2.17 — prev week / session / psychological
   CSessionFilter*      m_sessionFilter; // v2.17 — needed by m_extLevels.NearestSessionLevel() only

   int                  m_lookbackBars;           // closed bars examined for the reaction pattern (default 5)
   double               m_levelSearchATRMax;       // max distance, in ATR, for a level to count as "in range" (default 3.0)
   double               m_touchToleranceATRMult;   // how close a candle's range must come to the level, in ATR, to count as a touch (default 0.15)
   int                  m_absorptionMinTouches;    // touches required, with no break/rejection, to call it ABSORPTION (default 3)
   double               m_wickRejectionRatio;      // wick/range ratio required to call a candle a rejection (default 0.55, same default as MeanReversion.mqh)

   bool                 FindNearestLevel(bool forBuy, double atr, double price, double &levelPrice, ENUM_KEYLEVEL_SOURCE &source);
   bool                 CrossedFarSide(int shift, double levelPrice, double tol, bool forBuy);
   bool                 TouchedLevel(int shift, double levelPrice, double tol);
   bool                 RejectionWickAt(int shift, double levelPrice, bool forBuy);

public:
                        CKeyLevelEngine() : m_candles(NULL), m_sr(NULL), m_valueArea(NULL), m_liquidity(NULL), m_orderBlock(NULL),
                                             m_extLevels(NULL), m_sessionFilter(NULL),
                                             m_lookbackBars(5), m_levelSearchATRMax(3.0),
                                             m_touchToleranceATRMult(0.15), m_absorptionMinTouches(3),
                                             m_wickRejectionRatio(0.55) {}
   void                 Init(CCandleData* candles, CSupportResistance* sr, CValueAreaEngine* valueArea,
                              CLiquidity* liquidity, COrderBlock* orderBlock,
                              CExtendedKeyLevels* extLevels = NULL, CSessionFilter* sessionFilter = NULL)
     {
      m_candles = candles;
      m_sr = sr;
      m_valueArea = valueArea;
      m_liquidity = liquidity;
      m_orderBlock = orderBlock;
      // v2.17: both optional (default NULL) so existing call sites that
      // haven't been updated yet keep compiling and behave exactly as
      // before — FindNearestLevel() below skips these three sources
      // entirely when m_extLevels is NULL, same NULL-guard pattern
      // every other source here already follows.
      m_extLevels = extLevels;
      m_sessionFilter = sessionFilter;
     }
   // Defaults are starting points, not tuned constants — same
   // discipline note as every other Configure() in this codebase.
   void                 Configure(int lookbackBars = 5, double levelSearchATRMax = 3.0,
                                   double touchToleranceATRMult = 0.15, int absorptionMinTouches = 3,
                                   double wickRejectionRatio = 0.55)
     {
      m_lookbackBars = MathMax(2, lookbackBars);
      m_levelSearchATRMax = (levelSearchATRMax > 0) ? levelSearchATRMax : 3.0;
      m_touchToleranceATRMult = (touchToleranceATRMult >= 0) ? touchToleranceATRMult : 0.15;
      m_absorptionMinTouches = MathMax(2, absorptionMinTouches);
      m_wickRejectionRatio = (wickRejectionRatio > 0 && wickRejectionRatio <= 1.0) ? wickRejectionRatio : 0.55;
     }

   void                 Evaluate(bool forBuy, ENUM_KEYLEVEL_SOURCE &source, ENUM_KEYLEVEL_REACTION &reaction, double &reactionScore);
  };
//+------------------------------------------------------------------+
// forBuy -> nearest level ACTING AS SUPPORT (at/below price). !forBuy ->
// nearest level ACTING AS RESISTANCE (at/above price). "Nearest, no
// source-type favorites" — see file header.
bool CKeyLevelEngine::FindNearestLevel(bool forBuy, double atr, double price, double &levelPrice, ENUM_KEYLEVEL_SOURCE &source)
  {
   double bestDist = m_levelSearchATRMax * atr;
   bool found = false;
   levelPrice = 0.0;
   source = LEVEL_NONE;

   if(m_sr != NULL)
     {
      int n = m_sr.Count();
      for(int i = 0; i < n; i++)
        {
         SRZone z = m_sr.GetZone(i);
         double lvl = forBuy ? z.top : z.bottom;
         double dist = forBuy ? (price - lvl) : (lvl - price);
         if(dist < 0) dist = 0.0;
         if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_SR; found = true; }
        }
     }
   if(m_orderBlock != NULL)
     {
      int n = m_orderBlock.Count();
      for(int i = 0; i < n; i++)
        {
         OrderBlockZone z = m_orderBlock.GetZone(i);
         // Demand (FVG_BULL) acts as support -> use its top as the
         // support line facing price from below. Supply (FVG_BEAR)
         // acts as resistance -> use its bottom.
         if(forBuy && z.dir != FVG_BULL) continue;
         if(!forBuy && z.dir != FVG_BEAR) continue;
         double lvl = forBuy ? z.top : z.bottom;
         double dist = forBuy ? (price - lvl) : (lvl - price);
         if(dist < 0) dist = 0.0;
         if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_ORDER_BLOCK; found = true; }
        }
     }
   if(m_valueArea != NULL && m_valueArea.IsValid())
     {
      double lvl = forBuy ? m_valueArea.VAL() : m_valueArea.VAH();
      double dist = forBuy ? (price - lvl) : (lvl - price);
      if(dist < 0) dist = 0.0;
      if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_VALUE_AREA; found = true; }
     }
   if(m_liquidity != NULL)
     {
      ENUM_LIQ_TYPE target = forBuy ? LIQ_SELL_SIDE : LIQ_BUY_SIDE; // sell-side pool = stops below lows = support-adjacent; mirror for resistance
      int n = m_liquidity.EventCount();
      for(int i = 0; i < n; i++)
        {
         LiquidityEvent ev = m_liquidity.GetEvent(i);
         if(!ev.external) continue; // doc's "previous day high/low" maps to external D1 sweeps specifically, not internal equal-highs/lows
         if(ev.type != target) continue;
         double dist = forBuy ? (price - ev.price) : (ev.price - price);
         if(dist < 0) dist = 0.0;
         if(dist <= bestDist) { bestDist = dist; levelPrice = ev.price; source = LEVEL_LIQUIDITY_POOL; found = true; }
        }
     }
   // v2.17 — the three sources v2.14 left unwired. Each returns its own
   // nearest-on-the-requested-side candidate already (see
   // ExtendedKeyLevels.mqh), so this just folds those three single
   // candidates into the same "nearest wins, no source-type favorites"
   // comparison every source above already participates in.
   if(m_extLevels != NULL)
     {
      double lvl;
      if(m_extLevels.NearestPrevWeekLevel(forBuy, price, bestDist, lvl))
        {
         double dist = forBuy ? (price - lvl) : (lvl - price);
         if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_PREV_WEEK; found = true; }
        }
      if(m_candles != NULL && m_sessionFilter != NULL &&
         m_extLevels.NearestSessionLevel(forBuy, price, bestDist, lvl, m_candles, m_sessionFilter))
        {
         double dist = forBuy ? (price - lvl) : (lvl - price);
         if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_SESSION; found = true; }
        }
      if(m_extLevels.NearestRoundLevel(forBuy, price, bestDist, lvl))
        {
         double dist = forBuy ? (price - lvl) : (lvl - price);
         if(dist <= bestDist) { bestDist = dist; levelPrice = lvl; source = LEVEL_PSYCHOLOGICAL; found = true; }
        }
     }
   return found;
  }
//+------------------------------------------------------------------+
bool CKeyLevelEngine::CrossedFarSide(int shift, double levelPrice, double tol, bool forBuy)
  {
   CandleData cd = m_candles.GetCandle(shift);
   return forBuy ? (cd.close < levelPrice - tol) : (cd.close > levelPrice + tol);
  }
//+------------------------------------------------------------------+
bool CKeyLevelEngine::TouchedLevel(int shift, double levelPrice, double tol)
  {
   CandleData cd = m_candles.GetCandle(shift);
   return (cd.low <= levelPrice + tol && cd.high >= levelPrice - tol);
  }
//+------------------------------------------------------------------+
// Same shift-1-only "final, not still-forming" convention MeanReversion.mqh
// uses for its own wick check, applied per-shift here since this scans a window.
bool CKeyLevelEngine::RejectionWickAt(int shift, double levelPrice, bool forBuy)
  {
   CandleData cd = m_candles.GetCandle(shift);
   double range = cd.high - cd.low;
   if(range <= 0) return false;
   double lowerWick = MathMin(cd.open, cd.close) - cd.low;
   double upperWick = cd.high - MathMax(cd.open, cd.close);
   // forBuy (support, hold side = above): rejection = long lower wick
   // poking through the level while the close stays above it.
   return forBuy ? ((lowerWick / range) >= m_wickRejectionRatio && cd.low <= levelPrice)
                 : ((upperWick / range) >= m_wickRejectionRatio && cd.high >= levelPrice);
  }
//+------------------------------------------------------------------+
void CKeyLevelEngine::Evaluate(bool forBuy, ENUM_KEYLEVEL_SOURCE &source, ENUM_KEYLEVEL_REACTION &reaction, double &reactionScore)
  {
   source = LEVEL_NONE;
   reaction = REACTION_NONE;
   reactionScore = 0.0;

   if(m_candles == NULL || m_candles.Total() < m_lookbackBars + 1) return;
   double atr = m_candles.GetATR(0);
   if(atr <= 0) return;
   double price = m_candles.GetCandle(0).close; // live/current-bar proxy, same convention as the other two strategy modules

   double levelPrice;
   if(!FindNearestLevel(forBuy, atr, price, levelPrice, source))
     {
      source = LEVEL_NONE;
      return; // no level in range at all — stays NONE/NONE/0
     }

   double tol = atr * m_touchToleranceATRMult;

   bool crossed1 = CrossedFarSide(1, levelPrice, tol, forBuy);
   bool crossed2 = CrossedFarSide(2, levelPrice, tol, forBuy);

   if(crossed1 && crossed2)
     {
      reaction = REACTION_ACCEPTANCE;
      reactionScore = 90.0;
      return;
     }
   if(crossed1)
     {
      reaction = REACTION_BREAK;
      reactionScore = 75.0;
      return;
     }

   // Not currently on the far side (crossed1 is false past this point).
   // Was it on the far side at any point earlier in the window?
   bool wasCrossedEarlier = false;
   for(int s = 2; s <= m_lookbackBars; s++)
      if(CrossedFarSide(s, levelPrice, tol, forBuy)) { wasCrossedEarlier = true; break; }

   if(wasCrossedEarlier)
     {
      if(TouchedLevel(1, levelPrice, tol))
        {
         reaction = REACTION_RETEST;
         reactionScore = 70.0;
        }
      else
        {
         reaction = REACTION_FAILED_BREAK;
         reactionScore = 60.0;
        }
      return;
     }

   if(RejectionWickAt(1, levelPrice, forBuy))
     {
      reaction = REACTION_REJECTION;
      reactionScore = 65.0;
      return;
     }

   int touchCount = 0;
   for(int s = 1; s <= m_lookbackBars; s++)
      if(TouchedLevel(s, levelPrice, tol)) touchCount++;

   if(touchCount >= m_absorptionMinTouches)
     {
      reaction = REACTION_ABSORPTION;
      reactionScore = 40.0;
      return;
     }
   // A level was found and possibly touched once, but no pattern above
   // fit cleanly — stays NONE rather than force a weak guess into one
   // of the six named buckets.
  }
#endif
//+------------------------------------------------------------------+
