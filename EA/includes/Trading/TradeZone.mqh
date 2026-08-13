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
   double            m_slBufferATR;        // invalidation buffer beyond the FAR edge of the FVG, in ATR
   double            m_minStopSpreadMult;  // floor: total SL distance from entry never allowed below (current spread * this)

   bool              FindEntryFVG(ENUM_FVG_DIR dir, FVGZone &out);
   double            EnforceSpreadFloor(string symbol, double entry, double stopLoss, bool isBuy);

public:
                     CTradeDecision();
   // FIX (audit #23): slBufferATR replaces a hardcoded "+1.5 ATR" that was
   // added ON TOP OF the FVG width to build the stop, while
   // RiskEngine::ValidateSetup separately capped total SL distance at
   // InpMaxSLDistanceATR = 1.5. Since total SL distance was ALWAYS
   // (FVG width + 1.5 ATR), and minimum FVG width is 0.1 ATR, every setup
   // failed the max-SL gate by construction -- zero trades, ever, at
   // defaults. Buffer is now a small invalidation margin (default 0.25
   // ATR); the max-SL-distance gate in RiskEngine is what actually
   // decides whether a wide FVG is too risky, instead of the stop formula
   // deciding that unconditionally in the losing direction.
   // minStopSpreadMult: raised in review of InpSLBufferATR=0.25 -- a
   // small fixed ATR buffer can, on its own, put the stop inside the
   // spread on a wide-spread symbol/session, which silently inflates
   // effective risk (you're stopped by the spread crossing, not by price
   // actually moving against you) and eats a larger fraction of a tight
   // stop's R than a wider one would. This adds an explicit, independent
   // floor: total SL distance from the execution entry is never allowed
   // below (current spread * minStopSpreadMult), regardless of what the
   // ATR buffer alone would have produced. Default 3.0x is a starting
   // point, not a proven number -- check it against your actual broker's
   // realistic spread (Pepperstone/Exness Raw vs Standard accounts differ
   // meaningfully on XAUUSD) in the Strategy Tester before trusting it.
   void              Init(CCandleData* priceRef, CTFContext* fvgCtx, CTFContext* liqCtx, CScoringEngine* scoring,
                          double slBufferATR = 0.25, double minStopSpreadMult = 3.0);
   TradeSetup        GenerateBuySetup();
   TradeSetup        GenerateSellSetup();
   TradeSetup        GetLastSetup() const { return m_lastSetup; }
  };
//+------------------------------------------------------------------+
CTradeDecision::CTradeDecision() { ZeroMemory(m_lastSetup); m_slBufferATR = 0.25; m_minStopSpreadMult = 3.0; }
void CTradeDecision::Init(CCandleData* priceRef, CTFContext* fvgCtx, CTFContext* liqCtx, CScoringEngine* scoring,
                          double slBufferATR, double minStopSpreadMult)
  {
   m_priceRef = priceRef;
   m_fvgCtx = fvgCtx;
   m_liqCtx = liqCtx;
   m_scoring = scoring;
   m_slBufferATR = (slBufferATR > 0.0 ? slBufferATR : 0.25);
   m_minStopSpreadMult = (minStopSpreadMult >= 0.0 ? minStopSpreadMult : 3.0);
  }
//+------------------------------------------------------------------+
// Widens (never tightens) a stop so its distance from the real execution
// entry is at least (current spread * m_minStopSpreadMult). A stop
// tighter than a few spreads is not really "tight risk management" -- on
// a fast tick the spread crossing alone can trigger it before price has
// genuinely moved against the position, which is a cost, not edge.
double CTradeDecision::EnforceSpreadFloor(string symbol, double entry, double stopLoss, bool isBuy)
  {
   if(m_minStopSpreadMult <= 0.0) return stopLoss;
   long spreadPoints = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(spreadPoints <= 0 || point <= 0) return stopLoss;
   double minDist = spreadPoints * point * m_minStopSpreadMult;
   double curDist = MathAbs(entry - stopLoss);
   if(curDist >= minDist) return stopLoss;
   return isBuy ? (entry - minDist) : (entry + minDist);
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
   setup.stop_loss = entryFVG.bottom - m_slBufferATR * atr;
   setup.stop_loss = EnforceSpreadFloor(m_priceRef.Symbol(), setup.entry_top, setup.stop_loss, true); // FIX: spread floor, see Init() comment
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
   setup.stop_loss = entryFVG.top + m_slBufferATR * atr;
   setup.stop_loss = EnforceSpreadFloor(m_priceRef.Symbol(), setup.entry_bottom, setup.stop_loss, false); // FIX: spread floor, see Init() comment
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
