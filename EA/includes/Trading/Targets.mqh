//+------------------------------------------------------------------+
//|                                                Trading/Targets.mqh |
//+------------------------------------------------------------------+
#ifndef TARGETS_MQH
#define TARGETS_MQH

#include "../Core/Config.mqh"
#include "../Analysis/TFContext.mqh"

// Ranks resting liquidity by "how big a stop hunt would this be" and lays
// TP1/TP2/TP3 out along that ladder instead of fixed ATR multiples:
//   TP1 = nearest internal pool (equal highs/lows)      priority 75
//   TP2 = nearest external D1 high/low                  priority 90
//   TP3 = weekly high/low                                priority 100
// Any tier with no valid candidate (must be beyond price in the trade's
// direction, and — where a tier already exists before it — beyond the
// previous tier) falls back to an ATR step so a thin liquidity map never
// blocks target assignment outright.
class CTargetSelector
  {
private:
   static bool       NearestBeyond(CTFContext* liqCtx, bool wantInternal, bool forBuy,
                                   double entryPrice, double excludeBeyond, bool haveExclude,
                                   double &outPrice);
   static bool       WeeklyLevel(string symbol, bool forBuy, double &outPrice);

public:
   static void       AssignTargets(TradeSetup &setup, CTFContext* liqCtx, string symbol,
                                   double atr, double entryPrice);
  };
//+------------------------------------------------------------------+
// Scans liquidity pools for the nearest one on the correct side of price
// (LIQ_BUY_SIDE pools sit above price and are the natural target for a
// buy; LIQ_SELL_SIDE pools sit below and target a sell), optionally
// requiring it to sit beyond an already-chosen level (so TP2 can't land
// behind TP1).
bool CTargetSelector::NearestBeyond(CTFContext* liqCtx, bool wantInternal, bool forBuy,
                                    double entryPrice, double excludeBeyond, bool haveExclude,
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
      double price = forBuy ? p.price_top : p.price_bottom;
      bool onRightSide = forBuy ? (price > entryPrice) : (price < entryPrice);
      if(!onRightSide) continue;
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
bool CTargetSelector::WeeklyLevel(string symbol, bool forBuy, double &outPrice)
  {
   double v = forBuy ? iHigh(symbol, PERIOD_W1, 1) : iLow(symbol, PERIOD_W1, 1);
   if(v <= 0) return false;
   outPrice = v;
   return true;
  }
//+------------------------------------------------------------------+
void CTargetSelector::AssignTargets(TradeSetup &setup, CTFContext* liqCtx, string symbol,
                                    double atr, double entryPrice)
  {
   bool forBuy = (setup.type == ORDER_TYPE_BUY);
   double tp1, tp2, tp3;

   // TP1: nearest internal (equal highs/lows) pool.
   if(!NearestBeyond(liqCtx, true, forBuy, entryPrice, 0.0, false, tp1))
      tp1 = forBuy ? entryPrice + 2.0 * atr : entryPrice - 2.0 * atr;

   // TP2: nearest external (D1) pool beyond TP1.
   if(!NearestBeyond(liqCtx, false, forBuy, entryPrice, tp1, true, tp2))
      tp2 = forBuy ? tp1 + atr : tp1 - atr;

   // TP3: weekly high/low beyond TP2.
   double weekly;
   if(WeeklyLevel(symbol, forBuy, weekly) && (forBuy ? (weekly > tp2) : (weekly < tp2)))
      tp3 = weekly;
   else
      tp3 = forBuy ? tp2 + atr : tp2 - atr;

   setup.tp1 = tp1;
   setup.tp2 = tp2;
   setup.final_tp = tp3;
  }
#endif
//+------------------------------------------------------------------+
