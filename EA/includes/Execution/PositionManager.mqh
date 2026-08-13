//+------------------------------------------------------------------+
//|                                     Execution/PositionManager.mqh |
//+------------------------------------------------------------------+
#ifndef POSITIONMANAGER_MQH
#define POSITIONMANAGER_MQH

#include "OrderManager.mqh"
#include "BrokerAdapter.mqh"

// Everything that happens to a trade AFTER OrderManager gets it to
// FILLED: break-even, partial close at TP1, trailing the runner, and
// detecting closure. State order matches the documented lifecycle:
// Filled -> Protected -> Partial -> Runner -> Closed -> Archived.
class CPositionManager
  {
private:
   COrderManager*    m_orders;
   CBrokerAdapter*   m_broker;
   double            m_breakEvenAtR;      // move SL to entry once price is this many R in favor
   double            m_partialAtR;        // take TP1 partial once price is this many R in favor
   double            m_partialFraction;   // fraction of volume closed at TP1 (e.g. 0.5)
   double            m_trailAtrMult;      // runner trail distance, as an ATR multiple

   double            CurrentExitPrice(string symbol, bool isBuy);
   // FIX (#25): now takes the actual entry price explicitly (real fill,
   // via COrderManager::FillPriceAt) instead of deriving it from
   // dec.setup -- the theoretical FVG-edge entry is not what the
   // position is actually sitting on.
   double            RMultiple(const TradeDecisionRecord &dec, double entry, double price);

public:
   void              Init(COrderManager* orders, CBrokerAdapter* broker,
                          double breakEvenAtR, double partialAtR, double partialFraction, double trailAtrMult);
   void              OnTick(double currentAtr);
  };
//+------------------------------------------------------------------+
void CPositionManager::Init(COrderManager* orders, CBrokerAdapter* broker,
                            double breakEvenAtR, double partialAtR, double partialFraction, double trailAtrMult)
  {
   m_orders = orders;
   m_broker = broker;
   m_breakEvenAtR = breakEvenAtR;
   m_partialAtR = partialAtR;
   m_partialFraction = partialFraction;
   m_trailAtrMult = trailAtrMult;
  }
//+------------------------------------------------------------------+
double CPositionManager::CurrentExitPrice(string symbol, bool isBuy)
  {
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return 0.0;
   // Closing a long sells at bid; closing a short buys at ask.
   return isBuy ? tick.bid : tick.ask;
  }
//+------------------------------------------------------------------+
double CPositionManager::RMultiple(const TradeDecisionRecord &dec, double entry, double price)
  {
   bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
   double riskDist = MathAbs(entry - dec.setup.stop_loss);
   if(riskDist <= 0) return 0.0;
   double moveInFavor = isBuy ? (price - entry) : (entry - price);
   return moveInFavor / riskDist;
  }
//+------------------------------------------------------------------+
void CPositionManager::OnTick(double currentAtr)
  {
   for(int i = 0; i < m_orders.Total(); i++)
     {
      ENUM_TRADE_STATE state = m_orders.StateAt(i);
      if(state != TS_FILLED && state != TS_PROTECTED && state != TS_PARTIAL && state != TS_RUNNER)
         continue;

      ulong ticket = m_orders.TicketAt(i);
      if(!PositionSelectByTicket(ticket))
        {
         // Position is gone (SL/TP/manual close) — archive it and move on.
         m_orders.TransitionAt(i, TS_CLOSED);
         m_orders.TransitionAt(i, TS_ARCHIVED);
         continue;
        }

      TradeDecisionRecord dec = m_orders.DecisionAt(i);
      bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
      double entry = m_orders.FillPriceAt(i); // FIX (#25): actual fill, not the theoretical FVG edge
      double price = CurrentExitPrice(dec.symbol, isBuy);
      if(price <= 0) continue;
      double r = RMultiple(dec, entry, price);

      // 1. Break-even -- moves SL to the price this position ACTUALLY
      // entered at. Moving it to the theoretical entry instead (the old
      // behavior) could leave a "protected" trade still sitting at a
      // real loss if the fill was worse than the signal's theoretical
      // price.
      if(state == TS_FILLED && r >= m_breakEvenAtR)
        {
         if(m_broker.ModifySLTP(ticket, entry, dec.setup.final_tp))
            m_orders.TransitionAt(i, TS_PROTECTED);
        }

      // 2. Partial (only after break-even, matching the documented order).
      // NOTE (#26, flagged not "fixed"): this fires at m_partialAtR (e.g.
      // 2R), a fixed R-multiple -- not at dec.setup.tp1. TP1/TP2 are
      // liquidity-derived DISPLAY targets for the dashboard/signal feed;
      // they were never the live partial-close trigger, and a liquidity
      // level isn't guaranteed to be a good partial-exit point on every
      // setup. Real distinction, not a bug to silently paper over.
      if(state == TS_PROTECTED && r >= m_partialAtR)
        {
         double vol = m_orders.VolumeAt(i) * m_partialFraction;
         double minVol = SymbolInfoDouble(dec.symbol, SYMBOL_VOLUME_MIN);
         if(vol >= minVol && m_broker.ClosePartial(ticket, vol))
            m_orders.TransitionAt(i, TS_PARTIAL);
        }

      // 3. Hand the remainder off as a trailing runner
      if(state == TS_PARTIAL)
         m_orders.TransitionAt(i, TS_RUNNER);

      // 4. Trail the runner — only ever tighten, never widen, the stop
      if(state == TS_RUNNER && currentAtr > 0)
        {
         double newSL = isBuy ? price - m_trailAtrMult * currentAtr : price + m_trailAtrMult * currentAtr;
         double curSL = PositionGetDouble(POSITION_SL);
         bool improved = isBuy ? (newSL > curSL) : (newSL < curSL);
         if(improved)
            m_broker.ModifySLTP(ticket, newSL, dec.setup.final_tp);
        }
     }
  }
#endif
//+------------------------------------------------------------------+
