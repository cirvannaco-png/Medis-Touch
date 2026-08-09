//+------------------------------------------------------------------+
//|                                              Trading/TradeZone.mqh |
//+------------------------------------------------------------------+
#ifndef TRADEZONE_MQH
#define TRADEZONE_MQH

#include "../Core/Config.mqh"
#include "../Core/CandleData.mqh"
#include "../Analysis/TFContext.mqh"
#include "../Analysis/Scoring.mqh"
#include "Targets.mqh"

class CTradeDecision
  {
private:
   CCandleData*      m_priceRef;   // chart-TF candles, for current price only
   CTFContext*       m_fvgCtx;     // entry zone lives on the FVG timeframe
   CTFContext*       m_liqCtx;     // TP1 target lives on the liquidity timeframe
   CScoringEngine*   m_scoring;
   TradeSetup        m_lastSetup;

   bool              FindEntryFVG(ENUM_FVG_DIR dir, FVGZone &out);

public:
                     CTradeDecision();
   void              Init(CCandleData* priceRef, CTFContext* fvgCtx, CTFContext* liqCtx, CScoringEngine* scoring);
   TradeSetup        GenerateBuySetup();
   TradeSetup        GenerateSellSetup();
   TradeSetup        GetLastSetup() const { return m_lastSetup; }
  };
//+------------------------------------------------------------------+
CTradeDecision::CTradeDecision() { ZeroMemory(m_lastSetup); }
void CTradeDecision::Init(CCandleData* priceRef, CTFContext* fvgCtx, CTFContext* liqCtx, CScoringEngine* scoring)
  {
   m_priceRef = priceRef;
   m_fvgCtx = fvgCtx;
   m_liqCtx = liqCtx;
   m_scoring = scoring;
  }
//+------------------------------------------------------------------+
bool CTradeDecision::FindEntryFVG(ENUM_FVG_DIR dir, FVGZone &out)
  {
   if(m_fvgCtx == NULL || m_priceRef == NULL || m_priceRef.Total() == 0) return false;
   double price = m_priceRef.GetCandle(0).close;
   double atr = m_fvgCtx.candles.GetATR(0);
   if(atr <= 0) return false;

   for(int i = 0; i < m_fvgCtx.fvg.Count(); i++)
     {
      FVGZone z = m_fvgCtx.fvg.GetZone(i);
      if(z.dir != dir) continue;
      if(z.state != FVG_FRESH && z.state != FVG_TESTED) continue;
      double mid = (z.top + z.bottom) / 2.0;
      if(MathAbs(price - mid) / atr > 3.0) continue;
      out = z;
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
TradeSetup CTradeDecision::GenerateBuySetup()
  {
   TradeSetup setup;
   ZeroMemory(setup);
   if(m_priceRef == NULL || m_fvgCtx == NULL || m_scoring == NULL) return setup;

   double conf = m_scoring.CalculateConfidence(true);
   if(conf < 60.0) return setup;

   FVGZone entryFVG;
   if(!FindEntryFVG(FVG_BULL, entryFVG)) return setup;

   // Stop/target sizing uses the FVG-timeframe's own ATR — the entry zone
   // and the risk envelope should agree on which timeframe's volatility
   // they're measuring, instead of mixing chart-TF ATR with an H4/M15 zone.
   double atr = m_fvgCtx.candles.GetATR(0);
   if(atr <= 0) return setup;

   setup.type = ORDER_TYPE_BUY;
   setup.entry_top = entryFVG.top;
   setup.entry_bottom = entryFVG.bottom;
   setup.stop_loss = entryFVG.bottom - 1.5 * atr;
   CTargetSelector::AssignTargets(setup, m_liqCtx, m_priceRef.Symbol(), atr, setup.entry_bottom);
   setup.confidence = conf;
   setup.creation_time = TimeCurrent();
   setup.active = true;
   m_scoring.EvaluateReasons(true, setup.reasons);
   m_lastSetup = setup;
   return setup;
  }
//+------------------------------------------------------------------+
TradeSetup CTradeDecision::GenerateSellSetup()
  {
   TradeSetup setup;
   ZeroMemory(setup);
   if(m_priceRef == NULL || m_fvgCtx == NULL || m_scoring == NULL) return setup;

   double conf = m_scoring.CalculateConfidence(false);
   if(conf < 60.0) return setup;

   FVGZone entryFVG;
   if(!FindEntryFVG(FVG_BEAR, entryFVG)) return setup;

   double atr = m_fvgCtx.candles.GetATR(0);
   if(atr <= 0) return setup;

   setup.type = ORDER_TYPE_SELL;
   setup.entry_top = entryFVG.top;
   setup.entry_bottom = entryFVG.bottom;
   setup.stop_loss = entryFVG.top + 1.5 * atr;
   CTargetSelector::AssignTargets(setup, m_liqCtx, m_priceRef.Symbol(), atr, setup.entry_top);
   setup.confidence = conf;
   setup.creation_time = TimeCurrent();
   setup.active = true;
   m_scoring.EvaluateReasons(false, setup.reasons);
   m_lastSetup = setup;
   return setup;
  }
#endif
//+------------------------------------------------------------------+
