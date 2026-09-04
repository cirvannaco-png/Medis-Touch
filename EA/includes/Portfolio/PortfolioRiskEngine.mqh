//+------------------------------------------------------------------+
//| Portfolio/PortfolioRiskEngine.mqh                                |
//| Account-wide rolling-correlation and factor-exposure gate.        |
//| Conservative by design: correlated risk is counted regardless of  |
//| trade direction. No network, database or optimizer work occurs.  |
//+------------------------------------------------------------------+
#ifndef PORTFOLIORISKENGINE_MQH
#define PORTFOLIORISKENGINE_MQH

#include "../Trading/RiskEngine.mqh"

struct PortfolioRiskSnapshot
  {
   double totalRiskAmount;
   double correlatedRiskAmount;
   double factorRiskAmount;
   int    correlatedPositions;
   bool   valid;
  };

class CPortfolioRiskEngine
  {
private:
   int    m_correlationLookback;
   double m_correlationThreshold;
   double m_maxCorrelatedRiskPercent;
   double m_maxFactorRiskPercent;

   bool GetReturns(string symbol, int count, double &returns[]);
   double Correlation(string symbolA, string symbolB);
   double OpenRisk(ulong ticket, CRiskEngine &risk);
   string FactorGroup(string symbol);

public:
   void Init(int correlationLookback = 50, double correlationThreshold = 0.70,
             double maxCorrelatedRiskPercent = 1.50, double maxFactorRiskPercent = 2.00);
   bool BuildSnapshot(string proposedSymbol, double proposedRiskAmount, ulong magic,
                      CRiskEngine &risk, PortfolioRiskSnapshot &snapshot, string &reasonOut);
  };

void CPortfolioRiskEngine::Init(int correlationLookback, double correlationThreshold,
                                double maxCorrelatedRiskPercent, double maxFactorRiskPercent)
  {
   m_correlationLookback = MathMax(20, correlationLookback);
   m_correlationThreshold = MathMax(0.50, MathMin(0.95, correlationThreshold));
   m_maxCorrelatedRiskPercent = MathMax(0.0, maxCorrelatedRiskPercent);
   m_maxFactorRiskPercent = MathMax(0.0, maxFactorRiskPercent);
  }

bool CPortfolioRiskEngine::GetReturns(string symbol, int count, double &returns[])
  {
   double closes[];
   int copied = CopyClose(symbol, PERIOD_M15, 1, count + 1, closes);
   if(copied < count + 1) return false;
   ArrayResize(returns, count);
   for(int i = 1; i < copied; i++)
     {
      if(closes[i - 1] <= 0 || closes[i] <= 0) return false;
      returns[i - 1] = MathLog(closes[i] / closes[i - 1]);
     }
   return true;
  }

double CPortfolioRiskEngine::Correlation(string symbolA, string symbolB)
  {
   if(symbolA == symbolB) return 1.0;
   double a[], b[];
   if(!GetReturns(symbolA, m_correlationLookback, a)) return 0.0;
   if(!GetReturns(symbolB, m_correlationLookback, b)) return 0.0;
   int n = MathMin(ArraySize(a), ArraySize(b));
   if(n < 20) return 0.0;

   double ma = 0.0, mb = 0.0;
   for(int i = 0; i < n; i++) { ma += a[i]; mb += b[i]; }
   ma /= n;
   mb /= n;
   double cov = 0.0, va = 0.0, vb = 0.0;
   for(int i = 0; i < n; i++)
     {
      double da = a[i] - ma;
      double db = b[i] - mb;
      cov += da * db;
      va += da * da;
      vb += db * db;
     }
   if(va <= 0 || vb <= 0) return 0.0;
   return cov / MathSqrt(va * vb);
  }

double CPortfolioRiskEngine::OpenRisk(ulong ticket, CRiskEngine &risk)
  {
   if(!PositionSelectByTicket(ticket)) return 0.0;
   double sl = PositionGetDouble(POSITION_SL);
   if(sl <= 0) return 0.0;
   string symbol = PositionGetString(POSITION_SYMBOL);
   return risk.RiskAmountForLots(symbol,
                                 PositionGetDouble(POSITION_VOLUME),
                                 PositionGetDouble(POSITION_PRICE_OPEN), sl);
  }

string CPortfolioRiskEngine::FactorGroup(string symbol)
  {
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "XAG") >= 0) return "METALS";
   if(StringFind(symbol, "US30") >= 0 || StringFind(symbol, "NAS100") >= 0 || StringFind(symbol, "SPX") >= 0 ||
      StringFind(symbol, "GER40") >= 0 || StringFind(symbol, "UK100") >= 0 || StringFind(symbol, "JPN225") >= 0) return "RISK_ASSETS";
   if(StringFind(symbol, "BTC") >= 0 || StringFind(symbol, "ETH") >= 0 || StringFind(symbol, "XRP") >= 0) return "CRYPTO";
   return "FX";
  }

bool CPortfolioRiskEngine::BuildSnapshot(string proposedSymbol, double proposedRiskAmount, ulong magic,
                                         CRiskEngine &risk, PortfolioRiskSnapshot &snapshot, string &reasonOut)
  {
   snapshot.totalRiskAmount = proposedRiskAmount;
   snapshot.correlatedRiskAmount = proposedRiskAmount;
   snapshot.factorRiskAmount = proposedRiskAmount;
   snapshot.correlatedPositions = 0;
   snapshot.valid = true;
   reasonOut = "";

   string proposedFactor = FactorGroup(proposedSymbol);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0)
     {
      snapshot.valid = false;
      reasonOut = "invalid account equity";
      return false;
     }

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      double r = OpenRisk(ticket, risk);
      if(r <= 0)
        {
         if(PositionGetDouble(POSITION_SL) <= 0)
           {
            snapshot.valid = false;
            reasonOut = "existing position has no stop loss; portfolio risk is unknown";
            return false;
           }
         continue;
        }

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      snapshot.totalRiskAmount += r;
      if(FactorGroup(posSymbol) == proposedFactor)
         snapshot.factorRiskAmount += r;

      double corr = Correlation(proposedSymbol, posSymbol);
      if(MathAbs(corr) >= m_correlationThreshold)
        {
         snapshot.correlatedPositions++;
         snapshot.correlatedRiskAmount += r;
        }
     }

   if(m_maxCorrelatedRiskPercent > 0 &&
      snapshot.correlatedRiskAmount > equity * m_maxCorrelatedRiskPercent / 100.0)
     {
      snapshot.valid = false;
      reasonOut = StringFormat("correlated portfolio risk %.2f exceeds %.2f%% limit",
                               snapshot.correlatedRiskAmount, m_maxCorrelatedRiskPercent);
      return false;
     }
   if(m_maxFactorRiskPercent > 0 &&
      snapshot.factorRiskAmount > equity * m_maxFactorRiskPercent / 100.0)
     {
      snapshot.valid = false;
      reasonOut = StringFormat("factor exposure %s risk %.2f exceeds %.2f%% limit",
                               proposedFactor, snapshot.factorRiskAmount, m_maxFactorRiskPercent);
      return false;
     }
   return true;
  }

#endif // PORTFOLIORISKENGINE_MQH
