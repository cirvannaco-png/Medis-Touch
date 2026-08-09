//+------------------------------------------------------------------+
//|                                      SmartMoney/PremiumDiscount.mqh |
//+------------------------------------------------------------------+
#ifndef PREMIUMDISCOUNT_MQH
#define PREMIUMDISCOUNT_MQH

#include "../Core/Config.mqh"

// Static helper — no state, so no Init()/instance needed. Equilibrium is
// just the midpoint of a range; buys should only trigger below it
// (discount), sells only above it (premium). Deliberately takes a plain
// (high, low) pair rather than owning its own range source, so callers
// can feed it the impulse range (as the spec asks for), a swing range, or
// anything else without this file needing to know about ImpulseLeg.
class CPremiumDiscount
  {
public:
   static double     Equilibrium(double rangeHigh, double rangeLow) { return (rangeHigh + rangeLow) / 2.0; }
   static bool       IsDiscount(double price, double rangeHigh, double rangeLow)
     {
      if(rangeHigh <= rangeLow) return false;
      return price < Equilibrium(rangeHigh, rangeLow);
     }
   static bool       IsPremium(double price, double rangeHigh, double rangeLow)
     {
      if(rangeHigh <= rangeLow) return false;
      return price > Equilibrium(rangeHigh, rangeLow);
     }
   // Convenience wrapper for the impulse-range use case specifically.
   // LOCATION filter (see gate convention, Core/Config.mqh) — fails open
   // on purpose: with no range there's no "wrong side" to be on.
   static bool       OK(bool forBuy, double price, const ImpulseLeg &leg)
     {
      if(!leg.valid) return true; // no range to check against — don't block on missing data
      double hi = MathMax(leg.start_price, leg.end_price);
      double lo = MathMin(leg.start_price, leg.end_price);
      return forBuy ? IsDiscount(price, hi, lo) : IsPremium(price, hi, lo);
     }
  };
#endif
//+------------------------------------------------------------------+
