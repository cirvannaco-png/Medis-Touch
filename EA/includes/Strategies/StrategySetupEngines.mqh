//+------------------------------------------------------------------+
//| Strategies/StrategySetupEngines.mqh                              |
//| Independent strategy -> normalized TradeSetup constructors       |
//+------------------------------------------------------------------+
#ifndef STRATEGYSETUPENGINES_MQH
#define STRATEGYSETUPENGINES_MQH

#include "../Core/Config.mqh"
#include "../Analysis/TFContext.mqh"

// These engines answer ONLY setup construction. They do not size risk,
// select portfolio exposure, submit orders, or calibrate confidence.
// Every engine returns the same TradeSetup contract.

class CStrategySetupEngines
  {
private:
   CTFContext* m_ctx;
   double      m_entryATR;
   double      m_stopATR;
   int         m_lookback;

   double Highest(int startShift, int count);
   double Lowest(int startShift, int count);
   double MeanClose(int startShift, int count);
   bool   MakeCommon(TradeSetup &s, bool buy, double entry, double invalidation,
                     double confidence, double tp1, double tp2, double finalTP,
                     ENUM_SELECTED_STRATEGY strategy, string reason);

public:
   CStrategySetupEngines() : m_ctx(NULL), m_entryATR(0.10), m_stopATR(0.25), m_lookback(20) {}
   void Init(CTFContext* ctx, double entryATR=0.10, double stopATR=0.25, int lookback=20)
     {
      m_ctx=ctx;
      m_entryATR=(entryATR>0?entryATR:0.10);
      m_stopATR=(stopATR>0?stopATR:0.25);
      m_lookback=MathMax(5,lookback);
     }

   bool MomentumBreakout(bool buy, double score, TradeSetup &out);
   bool MeanReversion(bool buy, double score, TradeSetup &out);
   bool KeyLevelReaction(bool buy, double score, TradeSetup &out);
   bool Build(ENUM_SELECTED_STRATEGY strategy, bool buy, double score, TradeSetup &out);
  };

//+------------------------------------------------------------------+
double CStrategySetupEngines::Highest(int startShift, int count)
  {
   if(m_ctx==NULL) return 0.0;
   double v=0.0;
   int end=MathMin(m_ctx.candles.Total()-1,startShift+count-1);
   for(int i=startShift;i<=end;i++)
     {
      CandleData c=m_ctx.candles.GetCandle(i);
      if(v==0.0 || c.high>v) v=c.high;
     }
   return v;
  }
//+------------------------------------------------------------------+
double CStrategySetupEngines::Lowest(int startShift, int count)
  {
   if(m_ctx==NULL) return 0.0;
   double v=0.0;
   int end=MathMin(m_ctx.candles.Total()-1,startShift+count-1);
   for(int i=startShift;i<=end;i++)
     {
      CandleData c=m_ctx.candles.GetCandle(i);
      if(v==0.0 || c.low<v) v=c.low;
     }
   return v;
  }
//+------------------------------------------------------------------+
double CStrategySetupEngines::MeanClose(int startShift, int count)
  {
   if(m_ctx==NULL) return 0.0;
   int end=MathMin(m_ctx.candles.Total()-1,startShift+count-1);
   double sum=0.0; int n=0;
   for(int i=startShift;i<=end;i++) { sum+=m_ctx.candles.GetCandle(i).close; n++; }
   return n>0 ? sum/n : 0.0;
  }
//+------------------------------------------------------------------+
bool CStrategySetupEngines::MakeCommon(TradeSetup &s, bool buy, double entry,
                                       double invalidation, double confidence,
                                       double tp1, double tp2, double finalTP,
                                       ENUM_SELECTED_STRATEGY strategy, string reason)
  {
   ZeroMemory(s);
   if(m_ctx==NULL || entry<=0 || invalidation<=0 || confidence<=0) return false;
   if(buy && !(invalidation<entry && tp1>entry && tp2>=tp1 && finalTP>=tp2)) return false;
   if(!buy && !(invalidation>entry && tp1<entry && tp2<=tp1 && finalTP<=tp2)) return false;

   s.type=buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   s.entry_top=buy ? entry+m_entryATR*m_ctx.candles.GetATR(0) : entry+m_entryATR*m_ctx.candles.GetATR(0);
   s.entry_bottom=buy ? entry-m_entryATR*m_ctx.candles.GetATR(0) : entry-m_entryATR*m_ctx.candles.GetATR(0);
   s.stop_loss=invalidation;
   s.tp1=tp1; s.tp2=tp2; s.final_tp=finalTP;
   s.confidence=MathMin(100.0,MathMax(0.0,confidence));
   s.creation_time=TimeCurrent();
   s.active=true;
   s.reasons.selected_strategy=strategy;
   s.reasons.selected_strategy_score=s.confidence;
   s.reasons.risk_warning=reason;
   return true;
  }
//+------------------------------------------------------------------+
// Momentum/breakout: enter around the broken range edge, invalidate
// through the pre-break range, and project ATR-scaled continuation targets.
bool CStrategySetupEngines::MomentumBreakout(bool buy, double score, TradeSetup &out)
  {
   if(m_ctx==NULL || m_ctx.candles.Total()<m_lookback+3 || score<60) return false;
   double atr=m_ctx.candles.GetATR(0); if(atr<=0) return false;
   CandleData last=m_ctx.candles.GetCandle(1);
   double rangeHigh=Highest(2,m_lookback), rangeLow=Lowest(2,m_lookback);
   double entry=buy ? MathMax(last.close,rangeHigh) : MathMin(last.close,rangeLow);
   double invalid=buy ? rangeLow-m_stopATR*atr : rangeHigh+m_stopATR*atr;
   double dist=MathAbs(entry-invalid);
   return MakeCommon(out,buy,entry,invalid,score,
                     buy?entry+dist:entry-dist,
                     buy?entry+dist*1.75:entry-dist*1.75,
                     buy?entry+dist*2.75:entry-dist*2.75,
                     STRATEGY_MOMENTUM_BREAKOUT,
                     buy?"Momentum breakout: range expansion and continuation setup":"Momentum breakout: range breakdown and continuation setup");
  }
//+------------------------------------------------------------------+
// Mean reversion: fade an objectively stretched price back toward the
// rolling mean. Invalidation is beyond the stretch extreme, not an SMC FVG.
bool CStrategySetupEngines::MeanReversion(bool buy, double score, TradeSetup &out)
  {
   if(m_ctx==NULL || m_ctx.candles.Total()<m_lookback+2 || score<60) return false;
   double atr=m_ctx.candles.GetATR(0); if(atr<=0) return false;
   double mean=MeanClose(1,m_lookback);
   double hi=Highest(1,m_lookback), lo=Lowest(1,m_lookback);
   CandleData c=m_ctx.candles.GetCandle(0);
   double entry=buy ? MathMin(c.close,lo+0.15*atr) : MathMax(c.close,hi-0.15*atr);
   double invalid=buy ? lo-m_stopATR*atr : hi+m_stopATR*atr;
   double target1=buy ? mean : mean;
   double dist=MathAbs(entry-invalid);
   if(buy && target1<=entry) return false;
   if(!buy && target1>=entry) return false;
   return MakeCommon(out,buy,entry,invalid,score,
                     target1,
                     buy?entry+dist*1.25:entry-dist*1.25,
                     buy?entry+dist*2.0:entry-dist*2.0,
                     STRATEGY_MEAN_REVERSION,
                     buy?"Mean reversion: downside stretch reverting toward value":"Mean reversion: upside stretch reverting toward value");
  }
//+------------------------------------------------------------------+
// Key-level reaction: use the nearest confirmed rolling extreme as the
// level. Entry follows the rejection side; invalidation crosses the level.
bool CStrategySetupEngines::KeyLevelReaction(bool buy, double score, TradeSetup &out)
  {
   if(m_ctx==NULL || m_ctx.candles.Total()<m_lookback+3 || score<60) return false;
   double atr=m_ctx.candles.GetATR(0); if(atr<=0) return false;
   CandleData c=m_ctx.candles.GetCandle(1);
   double level=buy ? Lowest(2,m_lookback) : Highest(2,m_lookback);
   double entry=buy ? MathMax(c.close,level+0.05*atr) : MathMin(c.close,level-0.05*atr);
   double invalid=buy ? level- m_stopATR*atr : level+m_stopATR*atr;
   double dist=MathAbs(entry-invalid);
   return MakeCommon(out,buy,entry,invalid,score,
                     buy?entry+dist:entry-dist,
                     buy?entry+dist*1.75:entry-dist*1.75,
                     buy?entry+dist*2.5:entry-dist*2.5,
                     STRATEGY_KEY_LEVEL,
                     buy?"Key-level reaction: support rejection setup":"Key-level reaction: resistance rejection setup");
  }
//+------------------------------------------------------------------+
bool CStrategySetupEngines::Build(ENUM_SELECTED_STRATEGY strategy, bool buy, double score, TradeSetup &out)
  {
   switch(strategy)
     {
      case STRATEGY_MOMENTUM_BREAKOUT: return MomentumBreakout(buy,score,out);
      case STRATEGY_MEAN_REVERSION:    return MeanReversion(buy,score,out);
      case STRATEGY_KEY_LEVEL:         return KeyLevelReaction(buy,score,out);
      default: break; // SMC remains owned by the existing TradeZone path.
     }
   ZeroMemory(out);
   return false;
  }
#endif
//+------------------------------------------------------------------+
