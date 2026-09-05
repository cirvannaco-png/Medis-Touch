//+------------------------------------------------------------------+
//| Execution/PortfolioCoordinator.mqh                              |
//| Cross-symbol reservation, directional exposure and portfolio heat.|
//+------------------------------------------------------------------+
#ifndef PORTFOLIOCOORDINATOR_MQH
#define PORTFOLIOCOORDINATOR_MQH

struct MTPortfolioReservation
  { string request_id; string symbol; int direction; double risk_r; double volatility; double factor_market; double factor_usd; bool active; };

class CPortfolioCoordinator
  { private: MTPortfolioReservation m_rows[]; double m_maxHeat; double m_maxDirectional; double m_maxCluster;
    int Find(string id){for(int i=0;i<ArraySize(m_rows);i++)if(m_rows[i].request_id==id)return i;return -1;}
   public:
    void Init(double maxHeatR=3.0,double maxDirectionalR=2.0,double maxClusterR=2.0){m_maxHeat=maxHeatR;m_maxDirectional=maxDirectionalR;m_maxCluster=maxClusterR;ArrayResize(m_rows,0);}
    double Heat(){double x=0;for(int i=0;i<ArraySize(m_rows);i++)if(m_rows[i].active)x+=MathAbs(m_rows[i].risk_r);return x;}
    double Directional(int direction){double x=0;for(int i=0;i<ArraySize(m_rows);i++)if(m_rows[i].active)x+=(m_rows[i].direction==direction?1.0:-1.0)*MathAbs(m_rows[i].risk_r);return x;}
    bool Reserve(string id,string symbol,int direction,double riskR,double volatility,double factorMarket,double factorUsd,double correlatedRisk){
      if(Find(id)>=0||riskR<=0)return false;
      if(Heat()+riskR>m_maxHeat)return false;
      if(MathAbs(Directional(direction)+(direction>0?riskR:-riskR))>m_maxDirectional)return false;
      if(correlatedRisk+riskR>m_maxCluster)return false;
      int n=ArraySize(m_rows);ArrayResize(m_rows,n+1);m_rows[n].request_id=id;m_rows[n].symbol=symbol;m_rows[n].direction=direction;m_rows[n].risk_r=riskR;m_rows[n].volatility=volatility;m_rows[n].factor_market=factorMarket;m_rows[n].factor_usd=factorUsd;m_rows[n].active=true;return true;}
    void Release(string id){int i=Find(id);if(i>=0)m_rows[i].active=false;}
    double FactorMarket(){double x=0;for(int i=0;i<ArraySize(m_rows);i++)if(m_rows[i].active)x+=m_rows[i].factor_market*MathAbs(m_rows[i].risk_r);return x;}
    double FactorUsd(){double x=0;for(int i=0;i<ArraySize(m_rows);i++)if(m_rows[i].active)x+=m_rows[i].factor_usd*MathAbs(m_rows[i].risk_r);return x;}
  };
#endif
