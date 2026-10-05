//+------------------------------------------------------------------+
//|                                      SmartMoney/SMCExtensions.mqh |
//| Closed-bar operational IFVG/BPR/CISD/SMT/Breaker evidence.       |
//+------------------------------------------------------------------+
#ifndef SMCEXTENSIONS_MQH
#define SMCEXTENSIONS_MQH

#include "OrderBlock.mqh"

struct SMCExtensionResult
  {
   bool   ifvg_confirmed;
   bool   bpr_confirmed;
   bool   cisd_confirmed;
   bool   breaker_block_confirmed;
   bool   smt_confirmed;

   double ifvg_quality;
   double bpr_quality;
   double cisd_quality;
   double breaker_quality;
   double smt_quality;

   string smt_reference_symbol;
   double combined_quality;
  };

class CSMCExtensions
  {
private:
   CTFContext* m_ctx;
   string      m_smtReferenceSymbol;

   int    m_ifvgMaxAgeBars;
   int    m_bprMaxGapBars;
   int    m_cisdLookbackBars;
   int    m_cisdMaxRunBars;
   int    m_breakerMaxAgeBars;
   int    m_smtLookbackBars;
   int    m_smtMaxDriftBars;
   double m_smtMinCorrelation;
   bool   m_smtInverse;

   bool   PriceInside(double price,double top,double bottom,double tolerance) const;
   bool   FindIFVG(bool forBuy,double &top,double &bottom,double &quality) const;
   bool   FindBPR(bool forBuy,double &top,double &bottom,double &quality) const;
   bool   FindCISD(bool forBuy,double &level,double &quality) const;
   bool   FindBreaker(bool forBuy,double &top,double &bottom,double &quality) const;
   bool   FindSMT(bool forBuy,double &quality) const;

   double Correlation(const string symbol1,const string symbol2,
                      ENUM_TIMEFRAMES tf,int lookback) const;
   bool   FindSwing(const string symbol,ENUM_TIMEFRAMES tf,bool high,
                    int startShift,int maxShift,double &price,
                    datetime &time,int &shift) const;
   bool   FindReferenceSwingNear(const string symbol,ENUM_TIMEFRAMES tf,bool high,
                                 datetime targetTime,int approxShift,int maxDrift,
                                 double &price,datetime &time,int &shift) const;

public:
   CSMCExtensions();
   void Init(CTFContext* ctx,
             const string smtReferenceSymbol = "",
             int ifvgMaxAgeBars = 15,
             int bprMaxGapBars = 4,
             int cisdLookbackBars = 12,
             int cisdMaxRunBars = 5,
             int breakerMaxAgeBars = 20,
             int smtLookbackBars = 30,
             int smtMaxDriftBars = 2,
             double smtMinCorrelation = 0.70,
             bool smtInverseCorrelation = false);

   SMCExtensionResult Evaluate(bool forBuy) const;
  };

CSMCExtensions::CSMCExtensions()
  : m_ctx(NULL),
    m_smtReferenceSymbol(""),
    m_ifvgMaxAgeBars(15),
    m_bprMaxGapBars(4),
    m_cisdLookbackBars(12),
    m_cisdMaxRunBars(5),
    m_breakerMaxAgeBars(20),
    m_smtLookbackBars(30),
    m_smtMaxDriftBars(2),
    m_smtMinCorrelation(0.70),
    m_smtInverse(false)
  {}

void CSMCExtensions::Init(CTFContext* ctx,const string smtReferenceSymbol,
                          int ifvgMaxAgeBars,int bprMaxGapBars,
                          int cisdLookbackBars,int cisdMaxRunBars,
                          int breakerMaxAgeBars,int smtLookbackBars,
                          int smtMaxDriftBars,double smtMinCorrelation,
                          bool smtInverseCorrelation)
  {
   m_ctx=ctx;
   m_smtReferenceSymbol=smtReferenceSymbol;
   m_ifvgMaxAgeBars=MathMax(1,ifvgMaxAgeBars);
   m_bprMaxGapBars=MathMax(1,bprMaxGapBars);
   m_cisdLookbackBars=MathMax(3,cisdLookbackBars);
   m_cisdMaxRunBars=MathMax(1,cisdMaxRunBars);
   m_breakerMaxAgeBars=MathMax(1,breakerMaxAgeBars);
   m_smtLookbackBars=MathMax(10,smtLookbackBars);
   m_smtMaxDriftBars=MathMax(0,smtMaxDriftBars);
   m_smtMinCorrelation=MathMax(0.0,MathMin(1.0,smtMinCorrelation));
   m_smtInverse=smtInverseCorrelation;
  }

bool CSMCExtensions::PriceInside(double price,double top,double bottom,double tolerance) const
  {
   return price>=bottom-tolerance && price<=top+tolerance;
  }

// IFVG: an original FVG is closed through in the opposite direction,
// then revisited. All detection uses confirmed bars; it is evidence only.
bool CSMCExtensions::FindIFVG(bool forBuy,double &top,double &bottom,double &quality) const
  {
   top=0.0; bottom=0.0; quality=0.0;
   if(m_ctx==NULL || m_ctx.fvg.Count()==0 || m_ctx.candles.Total()<3) return false;

   double price=m_ctx.candles.GetCandle(1).close;
   double atr=m_ctx.candles.GetATR(1);
   if(atr<=0.0) return false;

   for(int i=0;i<m_ctx.fvg.Count();i++)
     {
      FVGZone z=m_ctx.fvg.GetZone(i);
      if(forBuy && z.dir!=FVG_BEAR) continue;
      if(!forBuy && z.dir!=FVG_BULL) continue;
      if(z.bar_index<2 || z.bar_index-1>m_ifvgMaxAgeBars) continue;

      bool flipped=false;
      for(int bar=1;bar<z.bar_index;bar++)
        {
         CandleData cd=m_ctx.candles.GetCandle(bar);
         if(forBuy && cd.close>z.top) { flipped=true; break; }
         if(!forBuy && cd.close<z.bottom) { flipped=true; break; }
        }
      if(!flipped) continue;
      if(!PriceInside(price,z.top,z.bottom,0.10*atr)) continue;

      double widthATR=MathAbs(z.top-z.bottom)/atr;
      quality=MathMax(0.0,MathMin(1.0,0.5+0.5*MathMin(widthATR,1.0)));
      top=z.top; bottom=z.bottom;
      return true;
     }
   return false;
  }

// BPR: overlap of a bullish and bearish FVG within a bounded distance.
bool CSMCExtensions::FindBPR(bool forBuy,double &top,double &bottom,double &quality) const
  {
   top=0.0; bottom=0.0; quality=0.0;
   if(m_ctx==NULL) return false;

   double price=m_ctx.candles.GetCandle(1).close;
   double atr=m_ctx.candles.GetATR(1);
   if(atr<=0.0) return false;

   for(int i=0;i<m_ctx.fvg.Count();i++)
     {
      FVGZone a=m_ctx.fvg.GetZone(i);
      if(a.bar_index<1) continue;

      for(int j=i+1;j<m_ctx.fvg.Count();j++)
        {
         FVGZone b=m_ctx.fvg.GetZone(j);
         if(b.bar_index<1 || a.dir==b.dir) continue;
         if(MathAbs(a.bar_index-b.bar_index)>m_bprMaxGapBars) continue;

         double overlapTop=MathMin(a.top,b.top);
         double overlapBottom=MathMax(a.bottom,b.bottom);
         if(overlapTop<=overlapBottom) continue;
         if(!PriceInside(price,overlapTop,overlapBottom,0.10*atr)) continue;

         double widthATR=(overlapTop-overlapBottom)/atr;
         quality=MathMax(0.0,MathMin(1.0,widthATR));
         top=overlapTop; bottom=overlapBottom;
         return true;
        }
     }
   return false;
  }

// CISD: the latest confirmed directional candle closes through the open
// of the oldest candle in the immediately preceding opposing run.
bool CSMCExtensions::FindCISD(bool forBuy,double &level,double &quality) const
  {
   level=0.0; quality=0.0;
   if(m_ctx==NULL) return false;

   int total=m_ctx.candles.Total();
   int limit=MathMin(m_cisdLookbackBars,total-m_cisdMaxRunBars-1);
   if(limit<1) return false;

   for(int bar=1;bar<=limit;bar++)
     {
      CandleData confirm=m_ctx.candles.GetCandle(bar);
      bool confirmDir=forBuy ? (confirm.close>confirm.open) : (confirm.close<confirm.open);
      if(!confirmDir) continue;

      int oldestRun=bar+1;
      int run=0;
      for(int k=bar+1;k<total && run<m_cisdMaxRunBars;k++)
        {
         CandleData prior=m_ctx.candles.GetCandle(k);
         bool opposing=forBuy ? (prior.close<prior.open) : (prior.close>prior.open);
         if(!opposing) break;
         oldestRun=k;
         run++;
        }
      if(run<=0) continue;

      level=m_ctx.candles.GetCandle(oldestRun).open;
      bool crossed=forBuy ? (confirm.close>level) : (confirm.close<level);
      if(!crossed) continue;

      double range=confirm.high-confirm.low;
      if(range<=0.0 || confirm.atr<=0.0) continue;
      double bodyRatio=MathAbs(confirm.close-confirm.open)/range;
      double rangeATR=range/confirm.atr;
      quality=MathMax(0.0,MathMin(1.0,0.5*bodyRatio+0.5*MathMin(rangeATR/2.0,1.0)));
      return true;
     }
   return false;
  }

// Breaker: a former opposite-direction OB is closed through, a later
// same-direction structure event is confirmed, and price retests the zone.
bool CSMCExtensions::FindBreaker(bool forBuy,double &top,double &bottom,double &quality) const
  {
   top=0.0; bottom=0.0; quality=0.0;
   if(m_ctx==NULL) return false;

   double price=m_ctx.candles.GetCandle(1).close;
   double atr=m_ctx.candles.GetATR(1);
   if(atr<=0.0) return false;

   for(int i=0;i<m_ctx.orderBlock.Count();i++)
     {
      OrderBlockZone z=m_ctx.orderBlock.GetZone(i);
      if(z.bar_index<2 || z.bar_index-1>m_breakerMaxAgeBars) continue;
      if(forBuy && z.dir!=FVG_BEAR) continue;
      if(!forBuy && z.dir!=FVG_BULL) continue;

      int flipBar=-1;
      for(int bar=1;bar<z.bar_index;bar++)
        {
         CandleData cd=m_ctx.candles.GetCandle(bar);
         if(forBuy && cd.close>z.top) { flipBar=bar; break; }
         if(!forBuy && cd.close<z.bottom) { flipBar=bar; break; }
        }
      if(flipBar<0) continue;

      bool structureAfterFlip=false;
      for(int k=0;k<m_ctx.bos.Count();k++)
        {
         BOSEvent ev=m_ctx.bos.GetBOS(k);
         if(ev.is_bullish==forBuy && ev.bar_index>=1 && ev.bar_index<flipBar)
           { structureAfterFlip=true; break; }
        }
      if(!structureAfterFlip)
        {
         for(int k=0;k<m_ctx.choch.Count();k++)
           {
            CHOCHPoint ev=m_ctx.choch.Get(k);
            if(ev.bullish==forBuy && ev.bar_index>=1 && ev.bar_index<flipBar)
              { structureAfterFlip=true; break; }
           }
        }
      if(!structureAfterFlip) continue;
      if(!PriceInside(price,z.top,z.bottom,0.10*atr)) continue;

      quality=MathMax(0.0,MathMin(1.0,
                        1.0-(double)(z.bar_index-1)/(double)m_breakerMaxAgeBars));
      top=z.top; bottom=z.bottom;
      return true;
     }
   return false;
  }

// SMT: compare confirmed swing highs/lows between the primary symbol and a
// related reference symbol. Correlation is a precondition, not proof of edge.
double CSMCExtensions::Correlation(const string symbol1,const string symbol2,
                                   ENUM_TIMEFRAMES tf,int lookback) const
  {
   if(symbol1=="" || symbol2=="" || lookback<3) return 0.0;

   double sx=0.0,sy=0.0,sxx=0.0,syy=0.0,sxy=0.0;
   int n=0;
   for(int i=1;i<=lookback;i++)
     {
      double a0=iClose(symbol1,tf,i), a1=iClose(symbol1,tf,i+1);
      double b0=iClose(symbol2,tf,i), b1=iClose(symbol2,tf,i+1);
      if(a0<=0.0 || a1<=0.0 || b0<=0.0 || b1<=0.0) continue;

      double x=(a0-a1)/a1;
      double y=(b0-b1)/b1;
      sx+=x; sy+=y; sxx+=x*x; syy+=y*y; sxy+=x*y; n++;
     }
   if(n<3) return 0.0;

   double cov=n*sxy-sx*sy;
   double vx=n*sxx-sx*sx;
   double vy=n*syy-sy*sy;
   if(vx<=0.0 || vy<=0.0) return 0.0;
   return cov/MathSqrt(vx*vy);
  }

bool CSMCExtensions::FindSwing(const string symbol,ENUM_TIMEFRAMES tf,bool high,
                                int startShift,int maxShift,double &price,
                                datetime &time,int &shift) const
  {
   price=0.0; time=0; shift=-1;
   int start=MathMax(2,startShift);
   for(int s=start;s<=maxShift;s++)
     {
      double h=iHigh(symbol,tf,s), l=iLow(symbol,tf,s);
      if(h<=0.0 || l<=0.0) continue;

      bool isSwing=high
                   ? (h>=iHigh(symbol,tf,s-1) && h>=iHigh(symbol,tf,s+1))
                   : (l<=iLow(symbol,tf,s-1) && l<=iLow(symbol,tf,s+1));
      if(isSwing)
        {
         price=high?h:l;
         time=iTime(symbol,tf,s);
         shift=s;
         return true;
        }
     }
   return false;
  }

bool CSMCExtensions::FindReferenceSwingNear(const string symbol,ENUM_TIMEFRAMES tf,
                                            bool high,datetime targetTime,int approxShift,
                                            int maxDrift,double &price,datetime &time,
                                            int &shift) const
  {
   price=0.0; time=0; shift=-1;
   long bestDelta=9223372036854775807LL;

   for(int d=-maxDrift;d<=maxDrift;d++)
     {
      int s=approxShift+d;
      if(s<2) continue;

      double p=0.0; datetime tt=0; int ss=-1;
      if(!FindSwing(symbol,tf,high,s,s,p,tt,ss)) continue;

      long delta=(long)MathAbs((double)((long)tt-(long)targetTime));
      if(delta<bestDelta)
        {
         bestDelta=delta;
         price=p; time=tt; shift=ss;
        }
     }
   return shift>=0;
  }

bool CSMCExtensions::FindSMT(bool forBuy,double &quality) const
  {
   quality=0.0;
   if(m_ctx==NULL || m_smtReferenceSymbol=="") return false;

   string primary=m_ctx.candles.Symbol();
   ENUM_TIMEFRAMES tf=m_ctx.tf;
   double corr=Correlation(primary,m_smtReferenceSymbol,tf,m_smtLookbackBars);
   if(!m_smtInverse && corr<m_smtMinCorrelation) return false;
   if(m_smtInverse && corr>-m_smtMinCorrelation) return false;

   double pLatest,pPrev,rLatest,rPrev;
   datetime tLatest,tPrev,rtLatest,rtPrev;
   int sLatest,sPrev,rsLatest,rsPrev;

   // Bullish SMT uses lows; bearish SMT uses highs.
   if(!FindSwing(primary,tf,!forBuy,2,m_smtLookbackBars,pLatest,tLatest,sLatest)) return false;
   if(!FindSwing(primary,tf,!forBuy,sLatest+1,m_smtLookbackBars,pPrev,tPrev,sPrev)) return false;

   int rApprox1=iBarShift(m_smtReferenceSymbol,tf,tLatest);
   int rApprox2=iBarShift(m_smtReferenceSymbol,tf,tPrev);
   if(rApprox1<2 || rApprox2<2) return false;

   if(!FindReferenceSwingNear(m_smtReferenceSymbol,tf,!forBuy,tLatest,rApprox1,m_smtMaxDriftBars,
                              rLatest,rtLatest,rsLatest)) return false;
   if(!FindReferenceSwingNear(m_smtReferenceSymbol,tf,!forBuy,tPrev,rApprox2,m_smtMaxDriftBars,
                              rPrev,rtPrev,rsPrev)) return false;

   bool divergence=false;
   if(forBuy)
      divergence=(pLatest<pPrev) &&
                 (m_smtInverse ? (rLatest<rPrev) : (rLatest>=rPrev));
   else
      divergence=(pLatest>pPrev) &&
                 (m_smtInverse ? (rLatest>rPrev) : (rLatest<=rPrev));
   if(!divergence) return false;

   double primaryMove=MathAbs(pLatest-pPrev);
   double refMove=MathAbs(rLatest-rPrev);
   double norm=(primaryMove>0.0)
               ? MathMin(primaryMove/(primaryMove+refMove+1e-12),1.0)
               : 0.5;
   quality=MathMax(0.0,MathMin(1.0,0.5*MathAbs(corr)+0.5*norm));
   return true;
  }

SMCExtensionResult CSMCExtensions::Evaluate(bool forBuy) const
  {
   SMCExtensionResult out;
   ZeroMemory(out);
   out.smt_reference_symbol=m_smtReferenceSymbol;
   if(m_ctx==NULL) return out;

   double top=0.0,bottom=0.0,q=0.0,level=0.0;
   if(FindIFVG(forBuy,top,bottom,q))
      { out.ifvg_confirmed=true; out.ifvg_quality=q; }
   if(FindBPR(forBuy,top,bottom,q))
      { out.bpr_confirmed=true; out.bpr_quality=q; }
   if(FindCISD(forBuy,level,q))
      { out.cisd_confirmed=true; out.cisd_quality=q; }
   if(FindBreaker(forBuy,top,bottom,q))
      { out.breaker_block_confirmed=true; out.breaker_quality=q; }
   if(FindSMT(forBuy,q))
      { out.smt_confirmed=true; out.smt_quality=q; }

   int n=0;
   double sum=0.0;
   if(out.ifvg_confirmed){sum+=out.ifvg_quality;n++;}
   if(out.bpr_confirmed){sum+=out.bpr_quality;n++;}
   if(out.cisd_confirmed){sum+=out.cisd_quality;n++;}
   if(out.breaker_block_confirmed){sum+=out.breaker_quality;n++;}
   if(out.smt_confirmed){sum+=out.smt_quality;n++;}
   out.combined_quality=n>0 ? 100.0*sum/n : 0.0;
   return out;
  }

#endif
//+------------------------------------------------------------------+
