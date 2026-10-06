//+------------------------------------------------------------------+
//|                                                Analysis/SMCChain.mqh |
//|  Deterministic causal SMC event-chain builder (v2.16).             |
//+------------------------------------------------------------------+
#ifndef SMCCHAIN_MQH
#define SMCCHAIN_MQH

#include "TFContext.mqh"

// A chain is a relationship between already-confirmed events on ONE
// execution timeframe. Higher-timeframe context is a separate validator.
// This avoids comparing unrelated bar indexes from different series.
enum ENUM_CHAIN_STATUS
  {
   CHAIN_INVALID = 0,
   CHAIN_INCOMPLETE,
   CHAIN_AMBIGUOUS,
   CHAIN_VALID
  };

struct SMCChain
  {
   ENUM_CHAIN_STATUS status;
   ENUM_SETUP_FAMILY family;
   ENUM_ORDER_TYPE direction;

   ulong chain_id;
   string chain_key;

   LiquidityEvent sweep;
   BOSEvent bos;
   CHOCHPoint choch;
   FVGZone fvg;

   bool has_sweep;
   bool has_bos;
   bool has_choch;
   bool has_fvg;
   bool has_rejection;
   bool has_displacement;
   bool location_ok;
   bool freshness_ok;
   bool invalidation_ok;

   int    displacement_bar_index;
   datetime displacement_time;

   double rejection_ratio;
   double penetration_atr;
   double displacement_atr;
   double body_ratio;
   double structure_strength;

   double location_midpoint;
   double invalidation_price;

   double quality;
   string failure_reason;
  };

class CSMCChainBuilder
  {
private:
   CTFContext* m_entryCtx;
   int         m_maxSweepToStructureBars;
   int         m_maxStructureToFVGBars;
   int         m_maxStructureAgeBars;
   int         m_maxFVGAgeBars;
   double      m_minDisplacementATR;
   double      m_minDisplacementBodyRatio;
   double      m_minStructureStrength;
   double      m_minRejectionRatio;
   bool        m_requirePremiumDiscount;
   // Experimental v2.27 policy: when enabled, premium/discount is a hard
   // gate only for reversal chains. Continuations keep it as ranking evidence
   // because the regime gate already requires trend-compatible continuation.
   // Default false preserves the existing v2.27 behavior until terminal
   // backtests validate the family-specific policy.
   bool        m_premiumDiscountReversalOnly;

   bool FindStructure(bool forBuy, int minBar, BOSEvent &bosOut, CHOCHPoint &chochOut,
                      bool &hasBos, bool &hasChoch, ENUM_SETUP_FAMILY &family);
   bool FindSweep(bool forBuy, const datetime structureTime, int structureBar,
                  LiquidityEvent &out);
   bool FindCausalFVG(bool forBuy, int structureBar, int displacementBar,
                      int sweepBar, int maxGapBars, int &ageBars, FVGZone &out);
   bool CalculateLocation(bool forBuy, datetime beforeTime, double price, double &midpoint);
   bool FindDisplacement(bool forBuy, int structureBar, int sweepBar,
                         int maxGapBars, int &dispBar,
                         double &atr, double &bodyRatio, double &rangeATR);
   bool ValidateRejection(bool forBuy, const LiquidityEvent &sweep, double &ratio, double &penetrationATR);
   double PenetrationShapeScore(double penetrationATR) const;
   ulong StableChainId(datetime structureTime, datetime fvgTime, bool forBuy) const;

public:
   CSMCChainBuilder();

   void Init(CTFContext* entryCtx,
             int maxSweepToStructureBars = 8,
             int maxStructureToFVGBars = 2,
             int maxStructureAgeBars = 5,
             int maxFVGAgeBars = 15,
             double minDisplacementATR = 1.0,
             double minDisplacementBodyRatio = 0.55,
             double minStructureStrength = 0.45,
             bool requirePremiumDiscount = true,
             double minRejectionRatio = 0.30,
             bool premiumDiscountReversalOnly = false);

   SMCChain Build(bool forBuy);
   string StatusToString(ENUM_CHAIN_STATUS status) const;
  };

CSMCChainBuilder::CSMCChainBuilder()
  : m_entryCtx(NULL),
    m_maxSweepToStructureBars(8),
    m_maxStructureToFVGBars(2),
    m_maxStructureAgeBars(5),
    m_maxFVGAgeBars(15),
    m_minDisplacementATR(1.0),
    m_minDisplacementBodyRatio(0.55),
    m_minStructureStrength(0.45),
    m_minRejectionRatio(0.30),
    m_requirePremiumDiscount(true),
    m_premiumDiscountReversalOnly(false)
  {}

void CSMCChainBuilder::Init(CTFContext* entryCtx,
                            int maxSweepToStructureBars,
                            int maxStructureToFVGBars,
                            int maxStructureAgeBars,
                            int maxFVGAgeBars,
                            double minDisplacementATR,
                            double minDisplacementBodyRatio,
                            double minStructureStrength,
                            bool requirePremiumDiscount,
                            double minRejectionRatio,
                            bool premiumDiscountReversalOnly)
  {
   m_entryCtx = entryCtx;
   m_maxSweepToStructureBars = MathMax(1, maxSweepToStructureBars);
   m_maxStructureToFVGBars = MathMax(0, maxStructureToFVGBars);
   m_maxStructureAgeBars = MathMax(1, maxStructureAgeBars);
   m_maxFVGAgeBars = MathMax(1, maxFVGAgeBars);
   m_minDisplacementATR = MathMax(0.1, minDisplacementATR);
   m_minDisplacementBodyRatio = MathMax(0.1, MathMin(1.0, minDisplacementBodyRatio));
   m_minStructureStrength = MathMax(0.0, MathMin(1.0, minStructureStrength));
   m_minRejectionRatio = MathMax(0.0, MathMin(1.0, minRejectionRatio));
   m_requirePremiumDiscount = requirePremiumDiscount;
   m_premiumDiscountReversalOnly = premiumDiscountReversalOnly;
  }

string CSMCChainBuilder::StatusToString(ENUM_CHAIN_STATUS status) const
  {
   switch(status)
     {
      case CHAIN_VALID:      return "VALID";
      case CHAIN_INCOMPLETE: return "INCOMPLETE";
      case CHAIN_AMBIGUOUS:  return "AMBIGUOUS";
      default:               return "INVALID";
     }
  }

ulong CSMCChainBuilder::StableChainId(datetime structureTime, datetime fvgTime, bool forBuy) const
  {
   // Stable within the EA's event model. The timestamps are confirmed-bar
   // timestamps; this is an identity key, not a cryptographic signature.
   ulong id = (ulong)structureTime;
   id = id * 131UL + (ulong)fvgTime;
   id = id * 2UL + (forBuy ? 1UL : 0UL);
   return id;
  }

bool CSMCChainBuilder::FindStructure(bool forBuy, int minBar, BOSEvent &bosOut, CHOCHPoint &chochOut,
                                     bool &hasBos, bool &hasChoch, ENUM_SETUP_FAMILY &family)
  {
   hasBos = false;
   hasChoch = false;
   family = SETUP_FAMILY_NONE;
   ZeroMemory(bosOut);
   ZeroMemory(chochOut);

   if(m_entryCtx == NULL) return false;

   int bestBar = 1000000000;

   for(int i = 0; i < m_entryCtx.bos.Count(); i++)
     {
      BOSEvent e = m_entryCtx.bos.GetBOS(i);
      if(e.bar_index < minBar) continue;
      if(e.bar_index < 1) continue;
      if(e.is_bullish != forBuy) continue;
      if(e.bar_index < bestBar)
        {
         bosOut = e;
         bestBar = e.bar_index;
         hasBos = true;
        }
     }

   for(int i = 0; i < m_entryCtx.choch.Count(); i++)
     {
      CHOCHPoint e = m_entryCtx.choch.Get(i);
      if(e.bar_index < minBar) continue;
      if(e.bar_index < 1) continue;
      if(e.bullish != forBuy) continue;
      if(e.bar_index < bestBar)
        {
         chochOut = e;
         bestBar = e.bar_index;
         hasChoch = true;
        }
     }

   if(hasChoch && (!hasBos || chochOut.bar_index < bosOut.bar_index))
      family = SETUP_FAMILY_REVERSAL;
   else if(hasBos)
      family = SETUP_FAMILY_CONTINUATION;
   else
      return false;

   return true;
  }

bool CSMCChainBuilder::FindSweep(bool forBuy, const datetime structureTime, int structureBar,
                                 LiquidityEvent &out)
  {
   if(m_entryCtx == NULL) return false;
   bool found = false;
   int bestGap = 1000000000;
   double bestStrength = -1.0;

   // BUY needs sell-side liquidity swept; SELL needs buy-side liquidity swept.
   ENUM_LIQ_TYPE wanted = forBuy ? LIQ_SELL_SIDE : LIQ_BUY_SIDE;

   for(int i = 0; i < m_entryCtx.liquidity.EventCount(); i++)
     {
      LiquidityEvent e = m_entryCtx.liquidity.GetEvent(i);
      if(!e.swept || e.bar_index < 1) continue;
      if(e.type != wanted) continue;
      if(e.time >= structureTime) continue;
      if(e.bar_index <= structureBar) continue;

      int gap = e.bar_index - structureBar; // same TF, series-index distance
      if(gap > m_maxSweepToStructureBars) continue;

      // Prefer the closest valid causal sweep; external pools and stronger
      // reclaim/penetration evidence break ties.
      double rank = (e.external ? 0.20 : 0.0) + e.strength;
      if(!found || gap < bestGap || (gap == bestGap && rank > bestStrength))
        {
         out = e;
         found = true;
         bestGap = gap;
         bestStrength = rank;
        }
     }
   return found;
  }

bool CSMCChainBuilder::ValidateRejection(bool forBuy, const LiquidityEvent &sweep,
                                          double &ratio, double &penetrationATR)
  {
   ratio = 0.0;
   penetrationATR = 0.0;
   if(m_entryCtx == NULL) return false;
   if(sweep.bar_index < 1 || sweep.bar_index >= m_entryCtx.candles.Total()) return false;

   CandleData cd = m_entryCtx.candles.GetCandle(sweep.bar_index);
   double atr = m_entryCtx.candles.GetATR(sweep.bar_index);
   if(atr <= 0.0) return false;

   double wick = forBuy ? (sweep.price - cd.low) : (cd.high - sweep.price);
   if(wick <= 0.0) return false;

   double reclaim = forBuy ? (cd.close - sweep.price) : (sweep.price - cd.close);
   ratio = MathMax(0.0, MathMin(reclaim / wick, 1.0));
   penetrationATR = wick / atr;

   // Require a completed reclaim. The liquidity detector already requires
   // close-back-inside; this adds a minimum amount of actual rejection.
   return (ratio >= m_minRejectionRatio);
  }

bool CSMCChainBuilder::FindDisplacement(bool forBuy, int structureBar, int sweepBar,
                                            int maxGapBars, int &dispBar,
                                            double &atr, double &bodyRatio, double &rangeATR)
  {
   dispBar = -1;
   atr = 0.0;
   bodyRatio = 0.0;
   rangeATR = 0.0;
   if(m_entryCtx == NULL) return false;

   int total = m_entryCtx.candles.Total();
   if(structureBar < 1 || structureBar >= total) return false;

   int oldest = (sweepBar >= 1)
                ? MathMin(sweepBar - 1, structureBar + MathMax(1, maxGapBars))
                : MathMin(total - 1, structureBar + MathMax(1, maxGapBars));

   // Series order: smaller index is newer. For a reversal chain there is
   // a causal ordering that matters: SWEEP -> DISPLACEMENT -> STRUCTURE.
   // The old implementation scanned from STRUCTURE toward the sweep, so a
   // strong BOS/CHoCH candle could be selected as the displacement even when
   // an earlier post-sweep displacement existed. That made the chain appear
   // causal while actually using the structural confirmation as its own
   // explanation. Prefer the qualifying displacement closest to the sweep;
   // for continuation chains (no sweep) retain the previous newest-first
   // behavior because the BOS itself can legitimately be the displacement.
   if(sweepBar >= 1)
     {
      for(int bar = oldest; bar >= structureBar; bar--)
        {
         CandleData cd = m_entryCtx.candles.GetCandle(bar);
      double a = m_entryCtx.candles.GetATR(bar);
      if(a <= 0.0) continue;

      double range = cd.high - cd.low;
      if(range <= 0.0) continue;

      bool directional = forBuy ? (cd.close > cd.open) : (cd.close < cd.open);
      double br = MathAbs(cd.close - cd.open) / range;
      double ra = range / a;

      if(!directional) continue;
      if(ra < m_minDisplacementATR) continue;
      if(br < m_minDisplacementBodyRatio) continue;

      dispBar = bar;
      atr = a;
      bodyRatio = br;
      rangeATR = ra;
         return true;
        }
     }
   else
     {
      for(int bar = structureBar; bar <= oldest; bar++)
        {
         CandleData cd = m_entryCtx.candles.GetCandle(bar);
         double a = m_entryCtx.candles.GetATR(bar);
         if(a <= 0.0) continue;

         double range = cd.high - cd.low;
         if(range <= 0.0) continue;

         bool directional = forBuy ? (cd.close > cd.open) : (cd.close < cd.open);
         double br = MathAbs(cd.close - cd.open) / range;
         double ra = range / a;

         if(!directional) continue;
         if(ra < m_minDisplacementATR) continue;
         if(br < m_minDisplacementBodyRatio) continue;

         dispBar = bar;
         atr = a;
         bodyRatio = br;
         rangeATR = ra;
         return true;
        }
     }

   return false;
  }
double CSMCChainBuilder::PenetrationShapeScore(double penetrationATR) const
  {
   // Smooth triangular preference: tiny pokes are weak, 0.03-0.60 ATR
   // penetrations receive full credit, and deeper penetrations taper back
   // toward zero instead of suffering the discontinuity in the old formula.
   if(penetrationATR <= 0.0) return 0.0;
   if(penetrationATR < 0.03)
      return penetrationATR / 0.03;
   if(penetrationATR <= 0.60)
      return 1.0;
   return MathMax(0.0, 1.0 - (penetrationATR - 0.60) / 0.60);
  }
bool CSMCChainBuilder::FindCausalFVG(bool forBuy, int structureBar, int displacementBar,
                                     int sweepBar, int maxGapBars, int &ageBars, FVGZone &out)
  {
   ageBars = -1;
   if(m_entryCtx == NULL) return false;

   bool found = false;
   int bestGap = 1000000000;
   int bestAge = 1000000000;

   for(int i = 0; i < m_entryCtx.fvg.Count(); i++)
     {
      FVGZone z = m_entryCtx.fvg.GetZone(i);
      if((z.dir == FVG_BULL) != forBuy) continue;
      if(z.state != FVG_FRESH && z.state != FVG_TESTED) continue;
      if(z.bar_index < 1) continue;

      int age = MathMax(0, z.bar_index - 2);
      if(age > m_maxFVGAgeBars) continue;

      // FVG bar_index is the middle candle of the three-candle pattern.
      // The latest candle that completes the FVG is therefore bar_index-1.
      // This lets a displacement candle itself complete the FVG without
      // incorrectly requiring the zone timestamp to be later than it.
      int fvgLatestBar = MathMax(1, z.bar_index - 1);

      int gapToStructure = MathAbs(fvgLatestBar - structureBar);
      int gapToDisplacement = MathAbs(fvgLatestBar - displacementBar);
      if(gapToStructure > maxGapBars && gapToDisplacement > maxGapBars)
         continue;

      // Causal ordering is strict: the FVG must be formed by the
      // displacement/structure sequence, not merely be spatially nearby.
      // In series indexing, smaller numbers are newer, so the FVG completion
      // must lie between the confirmed structure event and its displacement.
      if(fvgLatestBar < structureBar || fvgLatestBar > displacementBar)
         continue;

      // For reversal chains, the FVG must also post-date the sweep. Because
      // series indices increase into the past, anything older than the sweep
      // cannot be caused by the sweep/displacement sequence.
      if(sweepBar >= 1 && fvgLatestBar > sweepBar - 1)
         continue;

      if(!found || gapToDisplacement < bestGap ||
         (gapToDisplacement == bestGap && age < bestAge))
        {
         out = z;
         ageBars = age;
         bestGap = gapToDisplacement;
         bestAge = age;
         found = true;
        }
     }
   return found;
  }
bool CSMCChainBuilder::CalculateLocation(bool forBuy, datetime beforeTime, double price, double &midpoint)
  {
   midpoint = 0.0;
   if(m_entryCtx == NULL) return false;

   SwingPoint latestHigh;
   SwingPoint latestLow;
   ZeroMemory(latestHigh);
   ZeroMemory(latestLow);
   bool haveHigh = false, haveLow = false;

   for(int i = 0; i < m_entryCtx.swings.HighCount(); i++)
     {
      SwingPoint h = m_entryCtx.swings.GetHigh(i);
      if(h.time >= beforeTime) continue;
      if(!haveHigh || h.time > latestHigh.time)
        {
         latestHigh = h;
         haveHigh = true;
        }
     }
   for(int i = 0; i < m_entryCtx.swings.LowCount(); i++)
     {
      SwingPoint l = m_entryCtx.swings.GetLow(i);
      if(l.time >= beforeTime) continue;
      if(!haveLow || l.time > latestLow.time)
        {
         latestLow = l;
         haveLow = true;
        }
     }

   if(!haveHigh || !haveLow) return false;
   double hi = MathMax(latestHigh.price, latestLow.price);
   double lo = MathMin(latestHigh.price, latestLow.price);
   if(hi <= lo) return false;

   midpoint = lo + 0.5 * (hi - lo);
   return forBuy ? (price <= midpoint) : (price >= midpoint);
  }

SMCChain CSMCChainBuilder::Build(bool forBuy)
  {
   SMCChain c;
   ZeroMemory(c);
   c.status = CHAIN_INVALID;
   c.direction = forBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   c.family = SETUP_FAMILY_NONE;

   if(m_entryCtx == NULL || !m_entryCtx.candles.IsReady())
     {
      c.status = CHAIN_INCOMPLETE;
      c.failure_reason = "entry timeframe data not ready";
      return c;
     }

   // Try the newest structural event first, then walk backward if that
   // event is not causally explainable. This prevents one broken/latest
   // BOS from hiding an older but valid chain.
   int minStructureBar = 1;
   for(int attempt = 0; attempt < 8; attempt++)
     {
      bool hasBos = false, hasChoch = false;
      BOSEvent bos;
      CHOCHPoint choch;
      ENUM_SETUP_FAMILY family = SETUP_FAMILY_NONE;
      if(!FindStructure(forBuy, minStructureBar, bos, choch, hasBos, hasChoch, family))
        {
         c.status = CHAIN_INCOMPLETE;
         c.failure_reason = "no confirmed directional BOS/CHoCH";
         return c;
        }

      int structureBar = hasChoch ? choch.bar_index : bos.bar_index;
      datetime structureTime = hasChoch ? choch.time : bos.time;

      // Structure is a live thesis only for a bounded number of confirmed
      // bars. FVG freshness alone is insufficient: an old BOS can still have
      // a newly-retested FVG and create a stale signal.
      if(structureBar > m_maxStructureAgeBars)
        {
         minStructureBar = structureBar + 1;
         continue;
        }
      c.bos = bos;
      c.choch = choch;
      c.has_bos = hasBos;
      c.has_choch = hasChoch;
      c.family = family;
      c.structure_strength = hasChoch ? choch.strength : bos.strength;

      // BOS and CHoCH are both structural events. A weak CHoCH is not a
      // free pass merely because its label says "transition".
      if(c.structure_strength < m_minStructureStrength)
        {
         minStructureBar = structureBar + 1;
         continue;
        }

      bool haveSweep = FindSweep(forBuy, structureTime, structureBar, c.sweep);
      if(family == SETUP_FAMILY_REVERSAL && !haveSweep)
        {
         minStructureBar = structureBar + 1;
         continue;
        }

      c.has_sweep = haveSweep;

      if(haveSweep)
        {
         if(!ValidateRejection(forBuy, c.sweep, c.rejection_ratio, c.penetration_atr))
           {
            minStructureBar = structureBar + 1;
            continue;
           }
         c.has_rejection = true;
        }

      int sweepBar = haveSweep ? c.sweep.bar_index : -1;
      int dispBar = -1;
      double dispATR = 0.0, dispBody = 0.0, dispRangeATR = 0.0;
      if(!FindDisplacement(forBuy, structureBar, sweepBar,
                           m_maxSweepToStructureBars,
                           dispBar, dispATR, dispBody, dispRangeATR))
        {
         minStructureBar = structureBar + 1;
         continue;
        }

      c.has_displacement = true;
      c.displacement_bar_index = dispBar;
      c.displacement_time = m_entryCtx.candles.GetCandle(dispBar).time;
      c.displacement_atr = dispRangeATR;
      c.body_ratio = dispBody;

      int fvgAge = -1;
      if(!FindCausalFVG(forBuy, structureBar, dispBar, sweepBar,
                        m_maxStructureToFVGBars, fvgAge, c.fvg))
        {
         minStructureBar = structureBar + 1;
         continue;
        }

      c.has_fvg = true;
      c.freshness_ok = (fvgAge >= 0 && fvgAge <= m_maxFVGAgeBars);

      double fvgMid = (c.fvg.top + c.fvg.bottom) * 0.5;
      c.location_ok = CalculateLocation(forBuy, structureTime, fvgMid, c.location_midpoint);
      bool premiumDiscountGateApplies = m_requirePremiumDiscount &&
                                         (!m_premiumDiscountReversalOnly || family == SETUP_FAMILY_REVERSAL);
      if(premiumDiscountGateApplies && !c.location_ok)
        {
         minStructureBar = structureBar + 1;
         continue;
        }

      // Reversal invalidation belongs to the causal sweep. For a
      // continuation, use the causal displacement instead of any unrelated
      // nearby sweep; otherwise a coincidental sweep can widen the stop and
      // silently destroy the setup's intended risk geometry.
      bool useSweepInvalidation = (family == SETUP_FAMILY_REVERSAL && haveSweep);
      CandleData thesisCandle = useSweepInvalidation
                                 ? m_entryCtx.candles.GetCandle(c.sweep.bar_index)
                                 : m_entryCtx.candles.GetCandle(dispBar);
      c.invalidation_price = forBuy ? thesisCandle.low : thesisCandle.high;
      c.invalidation_ok = forBuy
                          ? (c.invalidation_price < c.fvg.bottom)
                          : (c.invalidation_price > c.fvg.top);
      if(!c.invalidation_ok)
        {
         minStructureBar = structureBar + 1;
         continue;
        }

      c.chain_id = StableChainId(structureTime, c.fvg.time, forBuy);
      c.chain_key = StringFormat("%s|%d|%I64d|%I64d|%d|%d|%d",
                                 m_entryCtx.candles.Symbol(),
                                 forBuy ? 1 : 0,
                                 (long)structureTime,
                                 (long)c.fvg.time,
                                 structureBar,
                                 dispBar,
                                 haveSweep ? c.sweep.bar_index : -1);

      // Sweep quality now uses two independent physical properties of the
      // reclaim: how convincingly price closed back through the pool and
      // whether the penetration depth looks like a plausible stop-run.
      // This prevents a shallow/tiny poke and an appropriately-sized sweep
      // from receiving identical chain quality merely because both closed
      // back inside the liquidity pool.
      double rejectionQ = haveSweep ? MathMax(0.0, MathMin(c.rejection_ratio, 1.0)) : 0.0;
      double penetrationQ = haveSweep ? PenetrationShapeScore(c.penetration_atr) : 0.0;
      double sweepQ = haveSweep ? MathMax(0.0, MathMin(0.65 * rejectionQ + 0.35 * penetrationQ, 1.0)) : 0.0;
      double dispQ = MathMax(0.0, MathMin(c.displacement_atr / 2.5, 1.0));
      double structQ = MathMax(0.0, MathMin(c.structure_strength, 1.0));
      // FVGZone.width is already normalized by the formation candle ATR
      // inside CFVG::Detect(). Do not divide it by a price ATR again.
      double fvgQ = MathMax(0.0, MathMin(c.fvg.width, 1.0));
      // FRESH receives full freshness credit; TESTED remains usable but is not equivalent to an untouched zone.
      double freshQ = c.freshness_ok ? (c.fvg.state == FVG_FRESH ? 1.0 : 0.5) : 0.0;
      // Under the experimental family-aware policy, continuation chains that
      // sit outside premium/discount remain valid but receive partial
      // location credit rather than a binary veto. Reversals remain binary.
      double locQ = c.location_ok ? 1.0 :
                    (m_premiumDiscountReversalOnly && family == SETUP_FAMILY_CONTINUATION ? 0.5 : 0.0);

      if(family == SETUP_FAMILY_REVERSAL)
         c.quality = 100.0 * (0.20 * sweepQ +
                              0.20 * dispQ +
                              0.20 * structQ +
                              0.15 * fvgQ +
                              0.10 * freshQ +
                              0.15 * locQ);
      else
         c.quality = 100.0 * (0.25 * dispQ +
                              0.25 * structQ +
                              0.20 * fvgQ +
                              0.15 * freshQ +
                              0.15 * locQ);

      c.status = CHAIN_VALID;
      return c;
     }

   c.status = CHAIN_INCOMPLETE;
   c.failure_reason = "no causally valid structural event in candidate window";
   return c;
  }

#endif
//+------------------------------------------------------------------+
