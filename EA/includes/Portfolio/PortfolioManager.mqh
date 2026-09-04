//+------------------------------------------------------------------+
//|                                     Portfolio/PortfolioManager.mqh |
//+------------------------------------------------------------------+
#ifndef PORTFOLIOMANAGER_MQH
#define PORTFOLIOMANAGER_MQH

#include "../Trading/RiskEngine.mqh"
#include "PortfolioRiskEngine.mqh"

// Account-wide pre-order portfolio gate. Simple hard limits remain here;
// rolling correlation, directional concentration and factor exposure are
// delegated to CPortfolioRiskEngine. No learning-plane or network work is
// permitted on the live tick path.
class CPortfolioManager
  {
private:
   double               m_maxPortfolioRiskPercent;
   int                  m_maxPositionsPerSymbol;
   int                  m_maxPositionsPerGroup;
   ulong                m_magic;
   CRiskEngine*         m_risk;
   CPortfolioRiskEngine m_riskEngine;

   string CorrelationGroup(string symbol);
   double OpenRiskAmount(ulong ticket);

public:
   void Init(double maxPortfolioRiskPercent, int maxPositionsPerSymbol,
             int maxPositionsPerGroup, ulong magic, CRiskEngine* risk,
             int correlationLookback = 50, double correlationThreshold = 0.70,
             double maxCorrelatedRiskPercent = 1.50, double maxFactorRiskPercent = 2.00);
   bool AllowNewTrade(string symbol, ENUM_ORDER_TYPE orderType,
                      double proposedRiskAmount, string &reasonOut);
  };

void CPortfolioManager::Init(double maxPortfolioRiskPercent, int maxPositionsPerSymbol,
                             int maxPositionsPerGroup, ulong magic, CRiskEngine* risk,
                             int correlationLookback, double correlationThreshold,
                             double maxCorrelatedRiskPercent, double maxFactorRiskPercent)
  {
   m_maxPortfolioRiskPercent = MathMax(0.0, maxPortfolioRiskPercent);
   m_maxPositionsPerSymbol = MathMax(0, maxPositionsPerSymbol);
   m_maxPositionsPerGroup = MathMax(0, maxPositionsPerGroup);
   m_magic = magic;
   m_risk = risk;
   m_riskEngine.Init(correlationLookback, correlationThreshold,
                     maxCorrelatedRiskPercent, maxFactorRiskPercent);
  }

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

double CPortfolioManager::OpenRiskAmount(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return 0.0;
   string symbol = PositionGetString(POSITION_SYMBOL);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double volume = PositionGetDouble(POSITION_VOLUME);
   if(sl == 0) return 0.0;
   return m_risk.RiskAmountForLots(symbol, volume, entry, sl);
  }

bool CPortfolioManager::AllowNewTrade(string symbol, ENUM_ORDER_TYPE orderType,
                                      double proposedRiskAmount, string &reasonOut)
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
   if(m_maxPortfolioRiskPercent > 0 && totalRisk > maxRiskAmount)
     {
      reasonOut = StringFormat("adding this trade would bring total open risk to %.2f, above the %.2f%% portfolio cap (%.2f)",
                               totalRisk, m_maxPortfolioRiskPercent, maxRiskAmount);
      return false;
     }

   PortfolioRiskSnapshot snapshot;
   string advancedReason;
   if(!m_riskEngine.BuildSnapshot(symbol, orderType, proposedRiskAmount, m_magic, m_risk, snapshot, advancedReason))
     {
      reasonOut = advancedReason;
      return false;
     }
   return true;
  }
#endif
//+------------------------------------------------------------------+
