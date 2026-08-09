//+------------------------------------------------------------------+
//|                                     Portfolio/PortfolioManager.mqh |
//+------------------------------------------------------------------+
#ifndef PORTFOLIOMANAGER_MQH
#define PORTFOLIOMANAGER_MQH

#include "../Trading/RiskEngine.mqh"

// Exposure and correlation gate, evaluated BEFORE Submit() ever reaches
// the broker. Deliberately account-wide, not symbol-local: if this EA
// (same magic number) runs on several charts/symbols at once, each
// instance's OrderManager only knows about ITS OWN trades — this class
// is the one place that looks at every open position under this magic
// number across the whole account before approving one more.
//
// SCOPE NOTE: "correlation" here is an asset-class bucket (FX / Metals /
// Indices / Crypto), not a rolling correlation coefficient computed from
// price history. A real pairwise correlation matrix is materially bigger
// infrastructure — its own price-history fetch/cache per symbol pair, a
// refresh cadence, a decision on window length — and is out of scope
// here by the same anti-complexity rule the rest of this codebase
// follows (see RiskEngine). A bucket cap still catches the common
// failure mode — five EURUSD-cluster BUYs stacked at once — without
// that machinery. Extend CorrelationGroup() if you need finer buckets.
class CPortfolioManager
  {
private:
   double            m_maxPortfolioRiskPercent;
   int               m_maxPositionsPerSymbol;
   int               m_maxPositionsPerGroup;
   ulong             m_magic;
   CRiskEngine*      m_risk;   // shared with the EA's own g_risk — see OpenRiskAmount() below

   string            CorrelationGroup(string symbol);
   double            OpenRiskAmount(ulong ticket);

public:
   void              Init(double maxPortfolioRiskPercent, int maxPositionsPerSymbol,
                          int maxPositionsPerGroup, ulong magic, CRiskEngine* risk);
   bool              AllowNewTrade(string symbol, double proposedRiskAmount, string &reasonOut);
  };
//+------------------------------------------------------------------+
void CPortfolioManager::Init(double maxPortfolioRiskPercent, int maxPositionsPerSymbol,
                             int maxPositionsPerGroup, ulong magic, CRiskEngine* risk)
  {
   m_maxPortfolioRiskPercent = maxPortfolioRiskPercent;
   m_maxPositionsPerSymbol = maxPositionsPerSymbol;
   m_maxPositionsPerGroup = maxPositionsPerGroup;
   m_magic = magic;
   m_risk = risk;
  }
//+------------------------------------------------------------------+
string CPortfolioManager::CorrelationGroup(string symbol)
  {
   if(StringFind(symbol, "BTC") >= 0 || StringFind(symbol, "ETH") >= 0 || StringFind(symbol, "XRP") >= 0)
      return "CRYPTO";
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "XAG") >= 0)
      return "METALS";
   if(StringFind(symbol, "US30") >= 0 || StringFind(symbol, "NAS100") >= 0 || StringFind(symbol, "SPX") >= 0 ||
      StringFind(symbol, "GER40") >= 0 || StringFind(symbol, "UK100") >= 0 || StringFind(symbol, "JPN225") >= 0)
      return "INDICES";
   return "FX";
  }
//+------------------------------------------------------------------+
// FIX: this used to reimplement CRiskEngine::RiskAmountForLots' tick-value
// math inline (tickValue/tickSize * distance * volume) as a second copy
// living in a second file — exactly the kind of drift risk RiskEngine's
// own comment on RiskAmountForLots was written to prevent. Now it calls
// the shared method directly, so a broker-quirk fix or rounding-mode
// change to that math only ever needs to happen in one place.
double CPortfolioManager::OpenRiskAmount(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return 0.0;
   string symbol = PositionGetString(POSITION_SYMBOL);
   double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl     = PositionGetDouble(POSITION_SL);
   double volume = PositionGetDouble(POSITION_VOLUME);
   if(sl == 0) return 0.0; // no stop set — can't quantify; AllowNewTrade treats this as a gap, not zero risk

   return m_risk.RiskAmountForLots(symbol, volume, entry, sl);
  }
//+------------------------------------------------------------------+
bool CPortfolioManager::AllowNewTrade(string symbol, double proposedRiskAmount, string &reasonOut)
  {
   reasonOut = "";
   string group = CorrelationGroup(symbol);

   double totalRisk = proposedRiskAmount;
   int symbolCount = 0;
   int groupCount = 0;
   bool anyUnknownRiskPosition = false;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic) continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      if(posSymbol == symbol) symbolCount++;
      if(CorrelationGroup(posSymbol) == group) groupCount++;

      double risk = OpenRiskAmount(ticket);
      if(risk <= 0 && PositionGetDouble(POSITION_SL) == 0) anyUnknownRiskPosition = true;
      totalRisk += risk;
     }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxRiskAmount = equity * (m_maxPortfolioRiskPercent / 100.0);

   if(symbolCount >= m_maxPositionsPerSymbol)
     {
      reasonOut = StringFormat("%s already has %d open position(s) under this magic number (limit %d)",
                               symbol, symbolCount, m_maxPositionsPerSymbol);
      return false;
     }
   if(groupCount >= m_maxPositionsPerGroup)
     {
      reasonOut = StringFormat("correlation group %s already has %d open position(s) (limit %d)",
                               group, groupCount, m_maxPositionsPerGroup);
      return false;
     }
   if(anyUnknownRiskPosition)
     {
      reasonOut = "an existing open position under this magic number has no stop loss set — portfolio risk can't be verified, refusing new trades until it's resolved";
      return false;
     }
   if(totalRisk > maxRiskAmount)
     {
      reasonOut = StringFormat("adding this trade would bring total open risk to %.2f, above the %.2f%% portfolio cap (%.2f)",
                               totalRisk, m_maxPortfolioRiskPercent, maxRiskAmount);
      return false;
     }
   return true;
  }
#endif
//+------------------------------------------------------------------+
