//+------------------------------------------------------------------+
//|                                     Execution/PositionManager.mqh |
//+------------------------------------------------------------------+
#ifndef POSITIONMANAGER_MQH
#define POSITIONMANAGER_MQH

#include "OrderManager.mqh"
#include "BrokerAdapter.mqh"

// Everything that happens to a trade AFTER OrderManager gets it to
// FILLED: break-even, target-aware partial close at TP1, TP2 profit
// protection, trailing the runner, and detecting closure. State order
// matches the documented lifecycle:
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
           {
            m_orders.TransitionAt(i, TS_PROTECTED);
            state = TS_PROTECTED; // allow TP1 milestone evaluation on this tick
           }
        }

      // 2. Target-aware TP1 partial. TP1 is the first member of the
      // validated target plan, so management follows the same structural
      // target chosen before risk approval. The legacy fixed-R trigger is
      // only a fallback for an old restored decision that predates TP1.
      double tp1 = dec.setup.tp1;
      bool tp1Directional = isBuy ? (tp1 > entry) : (tp1 < entry);
      bool tp1Reached = tp1Directional
                        ? (isBuy ? (price >= tp1) : (price <= tp1))
                        : (r >= m_partialAtR);

      // TP1 is a target milestone, not a side effect of the BE
      // configuration. If TP1 is reached before a configured BE threshold,
      // protect at the actual fill first, then take the planned partial.
      bool tp1ProtectionReady = (state == TS_PROTECTED);
      if(state == TS_FILLED && tp1Reached)
        {
         double curSL = PositionGetDouble(POSITION_SL);
         bool improveToEntry = isBuy ? (entry > curSL) : (entry < curSL);
         bool protectionOk = !improveToEntry || m_broker.ModifySLTP(ticket, entry, dec.setup.final_tp);
         if(protectionOk)
           {
            m_orders.TransitionAt(i, TS_PROTECTED);
            state = TS_PROTECTED;
            tp1ProtectionReady = true;
           }
        }

      if(tp1ProtectionReady && tp1Reached)
        {
         double vol = m_orders.VolumeAt(i) * m_partialFraction;
         double minVol = SymbolInfoDouble(dec.symbol, SYMBOL_VOLUME_MIN);
         if(vol >= minVol && m_broker.ClosePartial(ticket, vol))
           {
            m_orders.TransitionAt(i, TS_PARTIAL);
            state = TS_PARTIAL; // allow TP2 protection on the same tick if reached
           }
        }

      // 3. TP2 is a profit-protection milestone rather than a second
      // arbitrary partial. Once reached, move the stop to TP1. This uses
      // the actual target path while preserving the existing one-partial
      // state machine and runner economics.
      // 3. TP2 is the state transition into the runner. Until TP2 is
      // actually reached, the remainder stays in TS_PARTIAL with the
      // TP1-protection stop. This prevents the trailing stop from starting
      // prematurely and cutting the runner before the planned TP2 milestone.
      double tp2 = dec.setup.tp2;
      bool tp2Reached = (isBuy && tp2 > entry) ? (price >= tp2)
                       : (!isBuy && tp2 < entry) ? (price <= tp2)
                       : false;
      if(state == TS_PARTIAL && tp2Reached && tp1 > 0.0)
        {
         double lockSL = tp1;
         double curSL = PositionGetDouble(POSITION_SL);
         bool alreadyLocked = isBuy ? (curSL >= lockSL) : (curSL <= lockSL);
         bool protectionOk = alreadyLocked || m_broker.ModifySLTP(ticket, lockSL, dec.setup.final_tp);
         if(protectionOk)
           {
            m_orders.TransitionAt(i, TS_RUNNER);
            state = TS_RUNNER;
           }
        }

      // 4. Trail the runner — only after TP2 has transitioned the
      // position into TS_RUNNER. The stop only tightens; it never widens.
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
