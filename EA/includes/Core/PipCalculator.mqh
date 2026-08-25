//+------------------------------------------------------------------+
//|                                          Core/PipCalculator.mqh   |
//+------------------------------------------------------------------+
#ifndef PIPCALCULATOR_MQH
#define PIPCALCULATOR_MQH

// v2.9 addition. Scoring.mqh already computed this correctly (from
// SYMBOL_DIGITS/SYMBOL_POINT, not a hardcoded 0.0001) — this doesn't fix
// a live bug, it centralizes the ONE place that logic lives so every new
// consumer (Telegram payload pip display, dashboard, future risk
// tooling) uses the same definition instead of each re-deriving it and
// risking divergence on JPY pairs / gold / indices / 3-5 digit brokers.
//
// Convention: a "pip" is the traditional 4th decimal for most FX pairs
// (2nd for JPY pairs) — i.e. point*10 on a 5-digit broker, point*10 on a
// 3-digit JPY broker, and point*1 on a classic 4-digit broker. This
// matches MetaTrader's own informal pip convention, NOT SYMBOL_POINT
// directly (which is one price increment, not one pip, on 5/3-digit
// brokers). For gold/indices there's no universal "pip" — PipSize()
// still returns something scaled off SYMBOL_POINT/DIGITS, but treat the
// *_Points() variants as the reliable ones for those symbols; Pips() on
// XAUUSD is informational, not a market-standard unit.
class CPipCalculator
  {
public:
   static double     PipSize(string symbol)
     {
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(point <= 0) return 0.0001; // defensive fallback only — should never trigger on a valid symbol
      return (digits == 3 || digits == 5) ? point * 10.0 : point;
     }
   static double     PointSize(string symbol)
     {
      return SymbolInfoDouble(symbol, SYMBOL_POINT);
     }
   // Price distance -> pips (rounded to 1 decimal for display; callers
   // needing raw precision should divide by PipSize() themselves).
   static double     Pips(string symbol, double priceDistance)
     {
      double pip = PipSize(symbol);
      if(pip <= 0) return 0.0;
      return MathAbs(priceDistance) / pip;
     }
   static double     Points(string symbol, double priceDistance)
     {
      double pt = PointSize(symbol);
      if(pt <= 0) return 0.0;
      return MathAbs(priceDistance) / pt;
     }
   // Monetary value of one pip for `lots` lots on `symbol`. Uses
   // SYMBOL_TRADE_TICK_VALUE/TICK_SIZE so it's correct for FX, metals,
   // and indices alike, not just a "$10/pip/lot" FX assumption.
   static double     PipValue(string symbol, double lots)
     {
      double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize <= 0) return 0.0;
      double pip = PipSize(symbol);
      return (pip / tickSize) * tickValue * lots;
     }
   // Convenience formatter for signal cards / logs: "87 pips / 870 pts"
   // per the review's debugging recommendation (item #2 of the pips
   // batch) — showing both makes broker-digit mismatches visible instead
   // of silently wrong.
   static string     FormatDistance(string symbol, double priceDistance)
     {
      return StringFormat("%.1f pips / %.0f pts", Pips(symbol, priceDistance), Points(symbol, priceDistance));
     }
  };
#endif
//+------------------------------------------------------------------+
