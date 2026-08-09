//+------------------------------------------------------------------+
//|                                              Trading/RiskEngine.mqh |
//+------------------------------------------------------------------+
#ifndef RISKENGINE_MQH
#define RISKENGINE_MQH

#include "../Core/Config.mqh"
#include "TradeZone.mqh"

class CRiskEngine
  {
public:
   bool              ValidateSetup(TradeSetup &setup, double minRR, double maxSLDistanceATR, double currentATR);
   double            CalculateLotSize(string symbol, double riskPercent, double entry, double stopLoss,
                                      bool halveForReducedRisk, bool allowMinLotOverride, bool &exceededRiskBudget);
   double            RiskAmountForLots(string symbol, double lots, double entry, double stopLoss);
  };
//+------------------------------------------------------------------+
// NEW: nothing in v2.1 converted a validated setup into an actual lot
// size — risk was checked as a ratio (R:R, SL-in-ATR) but never turned
// into "how many lots does riskPercent of this account's equity buy at
// this stop distance". Required by the new Execution Engine; wasn't
// needed before because nothing placed real orders.
//
// FIXED: this used to clamp the result UP to the broker's minimum lot
// whenever riskPercent's true size fell below it — meaning a small
// account could silently risk more than InpRiskPercentPerTrade asked
// for, every single time it happened, with no signal that it had. The
// floor-rounding a few lines up exists specifically so this class never
// risks more than requested; clamping up at the far end quietly broke
// that same guarantee. Now: below broker minimum, the caller decides —
// reject the trade (default, and the only choice that keeps the risk%
// promise exact) or explicitly opt in to trading at min-lot anyway, in
// which case exceededRiskBudget tells the caller it happened so it can
// be logged, not silently absorbed.
double CRiskEngine::CalculateLotSize(string symbol, double riskPercent, double entry, double stopLoss,
                                     bool halveForReducedRisk, bool allowMinLotOverride, bool &exceededRiskBudget)
  {
   exceededRiskBudget = false;

   double slDistance = MathAbs(entry - stopLoss);
   if(slDistance <= 0) return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (riskPercent / 100.0);
   if(halveForReducedRisk) riskAmount *= 0.5;

   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0.0;

   double valuePerUnitDistance = tickValue / tickSize; // account-currency value of 1.0 price move, per lot
   double lossPerLot = slDistance * valuePerUnitDistance;
   if(lossPerLot <= 0) return 0.0;

   double rawLots = riskAmount / lossPerLot;

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   double lots = rawLots;
   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep; // round DOWN — never risk more than requested to hit a round lot

   if(lots < minLot)
     {
      if(!allowMinLotOverride)
         return 0.0; // correctly rejected — riskPercent genuinely doesn't buy one broker-minimum lot here
      exceededRiskBudget = true; // caller opted in: this trade WILL risk more than riskPercent
      lots = minLot;
     }

   lots = MathMin(maxLot, lots);
   return lots;
  }
//+------------------------------------------------------------------+
// NEW: the Portfolio Manager needs to know "if I let this trade through,
// how many account-currency dollars does it put at risk" so it can sum
// that against every other open position under this magic number. This
// is exactly the loss-per-lot math CalculateLotSize already does,
// inverted — kept in one place so the two never drift out of sync.
double CRiskEngine::RiskAmountForLots(string symbol, double lots, double entry, double stopLoss)
  {
   double slDistance = MathAbs(entry - stopLoss);
   if(slDistance <= 0 || lots <= 0) return 0.0;

   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0.0;

   double valuePerUnitDistance = tickValue / tickSize;
   return slDistance * valuePerUnitDistance * lots;
  }
//+------------------------------------------------------------------+
bool CRiskEngine::ValidateSetup(TradeSetup &setup, double minRR, double maxSLDistanceATR, double currentATR)
  {
   if(!setup.active) return false;
   // FIXED: this used to check R:R and the ATR-distance cap against
   // entry_bottom/entry_top — the *opposite*, more favorable edge of the
   // zone from what OrderManager::Submit() and OnTick()'s lot-sizing call
   // actually fill at. A setup could clear minRR/maxSLDistanceATR here on
   // paper and then execute at a real R:R below minRR / a real SL
   // distance beyond the cap, with nothing downstream catching it. Now
   // uses the same resolved entry as execution, via ResolveExecutionEntry()
   // (Core/Config.mqh) — one source of truth so this can't drift again.
   double entry = ResolveExecutionEntry(setup);
   double slDist = MathAbs(entry - setup.stop_loss);
   double tpDist = MathAbs(setup.tp1 - entry);
   if(slDist <= 0 || tpDist <= 0) return false;
   if(tpDist / slDist < minRR) return false;

   // FIX: maxSLDistanceATR was accepted as a parameter but never actually
   // checked against anything — a dead input that gave the impression of
   // risk control while doing nothing. Now it actually rejects setups
   // whose stop is unreasonably wide relative to current volatility.
   if(currentATR > 0)
     {
      double slDistATR = slDist / currentATR;
      if(slDistATR > maxSLDistanceATR) return false;
     }
   return true;
  }
#endif
//+------------------------------------------------------------------+
