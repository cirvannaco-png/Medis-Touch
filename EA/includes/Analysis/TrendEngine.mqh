//+------------------------------------------------------------------+
//|                                             Analysis/TrendEngine.mqh |
//+------------------------------------------------------------------+
#ifndef TRENDENGINE_MQH
#define TRENDENGINE_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../Structure/SwingDetector.mqh"
#include "../Structure/BOS.mqh"
#include "../Structure/CHOCH.mqh"

class CTrendEngine
  {
private:
   CSwingDetector*   m_swings;
   CBOS*             m_bos;
   CCHOCH*           m_choch;
   CCandleData*      m_candles;

   ENUM_TREND_STATE  DetermineTrend();

public:
                     CTrendEngine();
   void              Init(CSwingDetector* swings, CBOS* bos, CCHOCH* choch, CCandleData* candles);
   ENUM_TREND_STATE  GetCurrentTrend();
  };
//+------------------------------------------------------------------+
CTrendEngine::CTrendEngine() : m_swings(NULL), m_bos(NULL), m_choch(NULL), m_candles(NULL) {}
void CTrendEngine::Init(CSwingDetector* swings, CBOS* bos, CCHOCH* choch, CCandleData* candles)
  {
   m_swings = swings;
   m_bos = bos;
   m_choch = choch;
   m_candles = candles;
  }
//+------------------------------------------------------------------+
ENUM_TREND_STATE CTrendEngine::DetermineTrend()
  {
   if(m_swings == NULL || m_bos == NULL) return TREND_NEUTRAL;
   int hc = m_swings.HighCount();
   int lc = m_swings.LowCount();
   if(hc < 2 || lc < 2) return TREND_NEUTRAL;

   SwingPoint lastHigh = m_swings.GetHigh(0);
   SwingPoint prevHigh = m_swings.GetHigh(1);
   SwingPoint lastLow  = m_swings.GetLow(0);
   SwingPoint prevLow  = m_swings.GetLow(1);

   bool higherHigh = (lastHigh.price > prevHigh.price);
   bool higherLow  = (lastLow.price > prevLow.price);

   bool bullishBOS = false, bearishBOS = false;
   if(m_bos.Count() > 0)
     {
      BOSEvent recent = m_bos.GetBOS(0);
      bullishBOS = recent.is_bullish;
      bearishBOS = !recent.is_bullish;
     }

   if(higherHigh && higherLow && bullishBOS) return TREND_BULL_STRONG;
   if(higherHigh && higherLow) return TREND_BULL;
   if(!higherHigh && !higherLow && bearishBOS) return TREND_BEAR_STRONG;
   if(!higherHigh && !higherLow) return TREND_BEAR;
   return TREND_NEUTRAL;
  }
//+------------------------------------------------------------------+
ENUM_TREND_STATE CTrendEngine::GetCurrentTrend()
  {
   return DetermineTrend();
  }
#endif
//+------------------------------------------------------------------+
