//+------------------------------------------------------------------+
//|                                                Trading/Targets.mqh |
//+------------------------------------------------------------------+
#ifndef TARGETS_MQH
#define TARGETS_MQH

#include "../Core/Config.mqh"
#include "../Analysis/TFContext.mqh"

// v2.17 target engine. Targets are now constructed from a risk-normalized
// path rather than blindly taking the first pool found:
//   * only liquidity on the TRADE-DIRECTION side is eligible;
//   * every target must clear the configured minimum-RR distance;
//   * continuation/trending setups prefer external liquidity;
//   * reversal/ranging setups prefer internal liquidity;
//   * weekly liquidity is a later-tier anchor;
//   * ATR is a last-resort fallback, never the first choice.
// The selector also records per-target RR and quality so later outcome
// attribution can test target selection independently of entry quality.
class CTargetSelector
  {
private:
   static bool       NearestBeyond(CTFContext* liqCtx, bool wantInternal, bool forBuy,
                                   double entryPrice, double minDistance,
                                   double excludeBeyond, bool haveExclude,
                                   double &outPrice);
   static double      TargetQuality(int source, double rr, ENUM_MARKET_REGIME regime,
                                    ENUM_SETUP_FAMILY family);
   static bool       WeeklyLevel(string symbol, bool forBuy, double &outPrice);

public:
   static void       AssignTargets(TradeSetup &setup, CTFContext* liqCtx, string symbol,
                                   double atr, double entryPrice, double minRR = 1.5, double tp1MinRR = 1.25,
                                   ENUM_MARKET_REGIME regime = REGIME_UNDEFINED);
  };
//+------------------------------------------------------------------+
// Scans liquidity pools for the nearest one on the correct side of price
// (LIQ_BUY_SIDE pools sit above price and are the natural target for a
// buy; LIQ_SELL_SIDE pools sit below and target a sell), optionally
// requiring it to sit beyond an already-chosen level (so TP2 can't land
// behind TP1).
bool CTargetSelector::NearestBeyond(CTFContext* liqCtx, bool wantInternal, bool forBuy,
                                    double entryPrice, double minDistance,
                                    double excludeBeyond, bool haveExclude,
                                    double &outPrice)
  {
   outPrice = 0.0;
   if(liqCtx == NULL) return false;
   double best = 0.0;
   bool have = false;

   for(int i = 0; i < liqCtx.liquidity.PoolCount(); i++)
     {
      LiquidityPool p = liqCtx.liquidity.GetPool(i);
      if(p.external == wantInternal) continue; // wantInternal=true means we want external==false
      // A target must be a liquidity pool on the side price is expected to
      // seek. This prevents a spatially-near but semantically opposite pool
      // from becoming a target simply because it sits above/below entry.
      ENUM_LIQ_TYPE wantedType = forBuy ? LIQ_BUY_SIDE : LIQ_SELL_SIDE;
      if(p.type != wantedType) continue;
      double price = forBuy ? p.price_top : p.price_bottom;
      bool onRightSide = forBuy ? (price > entryPrice) : (price < entryPrice);
      if(!onRightSide) continue;
      double distance = MathAbs(price - entryPrice);
      if(minDistance > 0.0 && distance + 1e-10 < minDistance) continue;
      if(haveExclude)
        {
         bool beyondPrior = forBuy ? (price > excludeBeyond) : (price < excludeBeyond);
         if(!beyondPrior) continue;
        }
      bool better = !have || (forBuy ? (price < best) : (price > best)); // nearest = smallest distance
      if(better) { best = price; have = true; }
     }
   if(have) outPrice = best;
   return have;
  }
//+------------------------------------------------------------------+
double CTargetSelector::TargetQuality(int source, double rr, ENUM_MARKET_REGIME regime,
                                      ENUM_SETUP_FAMILY family)
  {
   if(rr <= 0.0) return 0.0;
   double sourceBase = 50.0;
   if(source == 1) sourceBase = 70.0;      // internal liquidity
   else if(source == 2) sourceBase = 85.0; // external liquidity
   else if(source == 3) sourceBase = 92.0; // previous closed week
   double idealRR = (family == SETUP_FAMILY_CONTINUATION && regime == REGIME_TRENDING) ? 2.5 : 1.8;
   double z = (rr - idealRR) / 1.5;
   double rrQuality = 100.0 * MathExp(-0.5 * z * z);
   double regimeBonus = 0.0;
   if(regime == REGIME_TRENDING && family == SETUP_FAMILY_CONTINUATION && source >= 2) regimeBonus = 10.0;
   if(regime == REGIME_RANGING && family == SETUP_FAMILY_REVERSAL && source == 1) regimeBonus = 10.0;
   if(source == 0) regimeBonus = -5.0;
   return MathMin(100.0, MathMax(0.0, 0.55 * sourceBase + 0.35 * rrQuality + regimeBonus));
  }
//+------------------------------------------------------------------+
bool CTargetSelector::WeeklyLevel(string symbol, bool forBuy, double &outPrice)
  {
   double v = forBuy ? iHigh(symbol, PERIOD_W1, 1) : iLow(symbol, PERIOD_W1, 1);
   if(v <= 0) return false;
   outPrice = v;
   return true;
  }
//+------------------------------------------------------------------+
void CTargetSelector::AssignTargets(TradeSetup &setup, CTFContext* liqCtx, string symbol,
                                    double atr, double entryPrice, double minRR, double tp1MinRR,
                                    ENUM_MARKET_REGIME regime)
  {
   setup.target_plan_valid = false;
   setup.tp1_rr = setup.tp2_rr = setup.tp3_rr = 0.0;
   setup.tp1_quality = setup.tp2_quality = setup.tp3_quality = 0.0;

   bool forBuy = (setup.type == ORDER_TYPE_BUY);
   double riskDist = MathAbs(entryPrice - setup.stop_loss);
   if(atr <= 0.0 || riskDist <= 0.0 || minRR <= 0.0) return;

   double minimumDistance = minRR * riskDist;
   // Fallback targets use explicit RR tiers rather than repeatedly adding the
   // minimum distance. With minRR=1.5 this yields a controlled 1.5R / 2.0R /
   // 3.0R ladder instead of the old 1.5R / 3.0R / 4.5R compounding.
   double fallbackTp1RR = MathMax(tp1MinRR, 1.25);
   double fallbackTp2RR = MathMax(MathMax(fallbackTp1RR + 0.5, 2.0), minRR + 0.5);
   double fallbackTp3RR = MathMax(MathMax(fallbackTp2RR + 0.75, 3.0), minRR + 1.5);

   double fallbackTp1Distance = fallbackTp1RR * riskDist;
   double fallbackTp2Distance = fallbackTp2RR * riskDist;
   double fallbackTp3Distance = fallbackTp3RR * riskDist;

   double tp1 = 0.0, tp2 = 0.0, tp3 = 0.0;
   int src1 = 0, src2 = 0, src3 = 0;

   // Regime is now allowed to influence TARGET PATH, but only after the
   // structural validator and regime permission layer have already passed.
   bool preferExternalFirst = (regime == REGIME_TRENDING && setup.family == SETUP_FAMILY_CONTINUATION);

   if(preferExternalFirst)
     {
      if(NearestBeyond(liqCtx, false, forBuy, entryPrice, tp1MinimumDistance, 0.0, false, tp1)) src1 = 2;
      else if(NearestBeyond(liqCtx, true, forBuy, entryPrice, tp1MinimumDistance, 0.0, false, tp1)) src1 = 1;
     }
   else
     {
      if(NearestBeyond(liqCtx, true, forBuy, entryPrice, tp1MinimumDistance, 0.0, false, tp1)) src1 = 1;
      else if(NearestBeyond(liqCtx, false, forBuy, entryPrice, tp1MinimumDistance, 0.0, false, tp1)) src1 = 2;
     }

   if(tp1 <= 0.0)
     {
      tp1 = forBuy ? entryPrice + fallbackTp1Distance : entryPrice - fallbackTp1Distance;
      src1 = 0;
     }

   // TP2: external liquidity beyond TP1, otherwise a weekly anchor, then
   // a monotonic volatility fallback. The candidate must still clear
   // the original entry-to-stop minimum-RR distance.
   if(NearestBeyond(liqCtx, false, forBuy, entryPrice, minimumDistance, tp1, true, tp2))
      src2 = 2;
   else
     {
      double weekly;
      if(WeeklyLevel(symbol, forBuy, weekly) &&
         (forBuy ? (weekly > tp1 && weekly > entryPrice + minimumDistance)
                 : (weekly < tp1 && weekly < entryPrice - minimumDistance)))
        {
         tp2 = weekly;
         src2 = 3;
        }
      else
        {
         tp2 = forBuy ? entryPrice + fallbackTp2Distance : entryPrice - fallbackTp2Distance;
         // If TP1 came from a distant liquidity pool, preserve strict
         // monotonicity by moving TP2 beyond that observed level.
         if(forBuy && tp2 <= tp1) tp2 = tp1 + 0.5 * riskDist;
         if(!forBuy && tp2 >= tp1) tp2 = tp1 - 0.5 * riskDist;
         src2 = 0;
        }
     }

   // TP3: closed previous-week liquidity beyond TP2. If it is unavailable
   // or already behind the path, extend with volatility rather than
   // inventing a non-monotonic target.
   double weekly3;
   if(WeeklyLevel(symbol, forBuy, weekly3) &&
      (forBuy ? (weekly3 > tp2) : (weekly3 < tp2)))
     {
      tp3 = weekly3;
      src3 = 3;
     }
   else
     {
      tp3 = forBuy ? entryPrice + fallbackTp3Distance : entryPrice - fallbackTp3Distance;
      // A liquidity-derived TP2 may exceed the nominal tier; never move TP3
      // backward. Keep at least 0.75R beyond TP2 in that case.
      if(forBuy && tp3 <= tp2) tp3 = tp2 + 0.75 * riskDist;
      if(!forBuy && tp3 >= tp2) tp3 = tp2 - 0.75 * riskDist;
      src3 = 0;
     }

   setup.tp1 = tp1;
   setup.tp2 = tp2;
   setup.final_tp = tp3;
   setup.tp1_rr = MathAbs(tp1 - entryPrice) / riskDist;
   setup.tp2_rr = MathAbs(tp2 - entryPrice) / riskDist;
   setup.tp3_rr = MathAbs(tp3 - entryPrice) / riskDist;
   setup.tp1_quality = TargetQuality(src1, setup.tp1_rr, regime, setup.family);
   setup.tp2_quality = TargetQuality(src2, setup.tp2_rr, regime, setup.family);
   setup.tp3_quality = TargetQuality(src3, setup.tp3_rr, regime, setup.family);

   // A target plan is valid only if all three levels are directional,
   // monotonic, and the first target itself clears minimum RR. The later
   // tiers inherit monotonicity from construction.
   bool directional = forBuy ? (tp1 > entryPrice && tp2 > tp1 && tp3 > tp2)
                             : (tp1 < entryPrice && tp2 < tp1 && tp3 < tp2);
   setup.target_plan_valid = directional &&
                             setup.tp1_rr >= tp1MinRR &&
                             setup.tp2_rr >= minRR &&
                             setup.tp3_rr >= setup.tp2_rr &&
                             setup.tp3_rr >= minRR;
  }
#endif
//+------------------------------------------------------------------+
