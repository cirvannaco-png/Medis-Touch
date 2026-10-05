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
                                      bool halveForReducedRisk, bool allowMinLotOverride, bool &exceededRiskBudget,
                                      double sizeMultiplier = 1.0); // RiskGuard's drawdown de-risk ramp — see Portfolio/RiskGuard.mqh
   double            RiskAmountForLots(string symbol, double lots, double entry, double stopLoss);
   bool              ValidateMargin(string symbol, ENUM_ORDER_TYPE type, double lots,
                                     double price, string &reason);
  };
// v2.16: broker-native loss estimate. OrderCalcProfit() is the
// authoritative cross-check for this instrument/account; manual tick-value
// math remains useful as a consistency check but is not trusted blindly.
double BrokerLossPerLot(string symbol, ENUM_ORDER_TYPE type, double entry, double stopLoss)
  {
   if(StringLen(symbol) == 0 || entry <= 0.0 || stopLoss <= 0.0) return 0.0;

   double profit = 0.0;
   ResetLastError();
   if(!OrderCalcProfit(type, symbol, 1.0, entry, stopLoss, profit))
     {
      PrintFormat("MedisTouch RiskEngine: OrderCalcProfit failed for %s (err=%d) — refusing to size the trade.",
                  symbol, GetLastError());
      return 0.0;
     }

   double loss = MathAbs(profit);
   return (loss > 0.0 && MathIsValidNumber(loss)) ? loss : 0.0;
  }

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
                                     bool halveForReducedRisk, bool allowMinLotOverride, bool &exceededRiskBudget,
                                     double sizeMultiplier)
  {
   exceededRiskBudget = false;

   double slDistance = MathAbs(entry - stopLoss);
   if(slDistance <= 0) return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (riskPercent / 100.0);
   if(halveForReducedRisk) riskAmount *= 0.5;
   riskAmount *= MathMax(0.0, MathMin(1.0, sizeMultiplier)); // RiskGuard drawdown ramp — 1.0 = no change

   ENUM_ORDER_TYPE orderType = (stopLoss < entry) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double brokerLossPerLot = BrokerLossPerLot(symbol, orderType, entry, stopLoss);
   if(brokerLossPerLot <= 0.0) return 0.0;

   // Independent tick-value estimate is retained as a diagnostic guard.
   // If broker-native and analytical loss disagree materially, sizing is
   // unknowable enough to justify a fail-closed rejection.
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double analyticalLoss = 0.0;
   if(tickSize > 0.0 && tickValue > 0.0)
      analyticalLoss = slDistance * (tickValue / tickSize);

   if(analyticalLoss > 0.0)
     {
      double deviation = MathAbs(analyticalLoss - brokerLossPerLot) / brokerLossPerLot;
      if(deviation > 0.10)
        {
         PrintFormat("MedisTouch RiskEngine: %s sizing mismatch — broker loss/lot %.2f vs analytical %.2f (%.1f%%). Refusing trade.",
                     symbol, brokerLossPerLot, analyticalLoss, deviation * 100.0);
         return 0.0;
        }
     }

   double lossPerLot = brokerLossPerLot;
   double rawLots = riskAmount / lossPerLot;

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0.0 || maxLot < minLot || lotStep <= 0.0) return 0.0;

   if(riskAmount <= 0.0) return 0.0;

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

   ENUM_ORDER_TYPE orderType = (stopLoss < entry) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double brokerLossPerLot = BrokerLossPerLot(symbol, orderType, entry, stopLoss);
   if(brokerLossPerLot <= 0.0) return 0.0;
   return brokerLossPerLot * lots;
  }
//+------------------------------------------------------------------+
bool CRiskEngine::ValidateSetup(TradeSetup &setup, double minRR, double maxSLDistanceATR, double currentATR)
  {
   if(!setup.active) return false;
   if(setup.status != SETUP_ACTIVE) return false;
   if(!setup.structural_valid) return false;
   if(!setup.target_plan_valid) return false;

   // Structural thesis and protective order are separate. The actual stop
   // must remain beyond the thesis invalidation boundary.
   if(setup.invalidation <= 0.0 || setup.stop_loss <= 0.0) return false;
   if(setup.type == ORDER_TYPE_BUY)
     {
      if(setup.invalidation >= setup.entry_bottom) return false;
      if(setup.stop_loss >= setup.invalidation) return false;
     }
   else if(setup.type == ORDER_TYPE_SELL)
     {
      if(setup.invalidation <= setup.entry_top) return false;
      if(setup.stop_loss <= setup.invalidation) return false;
     }
   else return false;

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
   double tp1Dist = MathAbs(setup.tp1 - entry);
   double finalDist = MathAbs(setup.final_tp - entry);
   if(slDist <= 0 || tp1Dist <= 0 || finalDist <= 0) return false;
   // TP1 is deliberately allowed to be the closer high-probability partial.
   // Validate the configured overall RR against the final target; the
   // target engine already validated TP1 against its dedicated TP1 minimum.
   if(finalDist / slDist < minRR) return false;

   // FIX: maxSLDistanceATR was accepted as a parameter but never actually
   // checked against anything — a dead input that gave the impression of
   // risk control while doing nothing. Now it actually rejects setups
   // whose stop is unreasonably wide relative to current volatility.
   if(maxSLDistanceATR > 0.0)
     {
      if(currentATR <= 0.0) return false;
      double slDistATR = slDist / currentATR;
      if(slDistATR > maxSLDistanceATR) return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
bool CRiskEngine::ValidateMargin(string symbol, ENUM_ORDER_TYPE type, double lots,
                                  double price, string &reason)
  {
   reason = "";
   if(lots <= 0.0 || price <= 0.0)
     {
      reason = "invalid lots or reference price";
      return false;
     }

   double margin = 0.0;
   ResetLastError();
   if(!OrderCalcMargin(type, symbol, lots, price, margin))
     {
      reason = StringFormat("OrderCalcMargin failed (err=%d)", GetLastError());
      return false;
     }
   if(margin <= 0.0 || !MathIsValidNumber(margin))
     {
      reason = "broker returned invalid required margin";
      return false;
     }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin <= 0.0 || margin > freeMargin)
     {
      reason = StringFormat("required margin %.2f exceeds free margin %.2f", margin, freeMargin);
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+

#endif
//+------------------------------------------------------------------+

