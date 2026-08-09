//+------------------------------------------------------------------+
//|                                        Execution/OrderManager.mqh |
//+------------------------------------------------------------------+
#ifndef ORDERMANAGER_MQH
#define ORDERMANAGER_MQH

#include "../Decision/TradeDecision.mqh"
#include "TradeStateMachine.mqh"
#include "BrokerAdapter.mqh"

// One decision's full order lifecycle: the immutable decision it came
// from, its state machine, and the volume actually sized for it.
struct ManagedTrade
  {
   TradeDecisionRecord  decision;
   CTradeStateMachine   fsm;
   double               volume;
  };
//+------------------------------------------------------------------+
// Owns every ManagedTrade from Submit() through FILLED/REJECTED/
// CANCELLED. Everything past FILLED (break-even, partials, trailing) is
// CPositionManager's job — this class exposes read/mutate accessors
// instead of the raw array so PositionManager never needs its own copy of
// the trade list.
class COrderManager
  {
private:
   CBrokerAdapter*     m_broker;
   ManagedTrade        m_trades[];
   int                 m_maxOpen;
   CProductionMonitor* m_monitor; // C004 FIX: threaded through so every fsm gets bound — see BindMonitor() call sites below

   int               FindByDecisionId(long id);

public:
   void              Init(CBrokerAdapter* broker, int maxOpenTrades, CProductionMonitor* monitor);
   bool              Submit(const TradeDecisionRecord &decision, double volume, bool useMarket, ulong &ticketOut);
   bool              RestoreTrade(const TradeDecisionRecord &decision, double volume, ulong ticket, ENUM_TRADE_STATE state);
   int               OpenCount();
   int               Total() { return ArraySize(m_trades); }
   void              Prune();  // drop ARCHIVED/CANCELLED/REJECTED rows to keep the array bounded
   bool              MarkFilledFromPending(ulong orderTicket, ulong positionTicket);

   // Accessors used by PositionManager instead of direct array access.
   ENUM_TRADE_STATE     StateAt(int idx)              { return m_trades[idx].fsm.State(); }
   ulong                TicketAt(int idx)              { return m_trades[idx].fsm.Ticket(); }
   TradeDecisionRecord  DecisionAt(int idx)            { return m_trades[idx].decision; }
   double               VolumeAt(int idx)              { return m_trades[idx].volume; }
   bool                 TransitionAt(int idx, ENUM_TRADE_STATE to) { return m_trades[idx].fsm.Transition(to); }
  };
//+------------------------------------------------------------------+
void COrderManager::Init(CBrokerAdapter* broker, int maxOpenTrades, CProductionMonitor* monitor)
  {
   m_broker = broker;
   m_maxOpen = maxOpenTrades;
   m_monitor = monitor;
   ArrayResize(m_trades, 0);
  }
//+------------------------------------------------------------------+
int COrderManager::FindByDecisionId(long id)
  {
   for(int i = 0; i < ArraySize(m_trades); i++)
      if(m_trades[i].decision.decision_id == id) return i;
   return -1;
  }
//+------------------------------------------------------------------+
int COrderManager::OpenCount()
  {
   int c = 0;
   for(int i = 0; i < ArraySize(m_trades); i++)
     {
      ENUM_TRADE_STATE s = m_trades[i].fsm.State();
      if(s == TS_PENDING || s == TS_FILLED || s == TS_PROTECTED || s == TS_PARTIAL || s == TS_RUNNER)
         c++;
     }
   return c;
  }
//+------------------------------------------------------------------+
void COrderManager::Prune()
  {
   ManagedTrade kept[];
   int n = 0;
   ArrayResize(kept, ArraySize(m_trades));
   for(int i = 0; i < ArraySize(m_trades); i++)
     {
      ENUM_TRADE_STATE s = m_trades[i].fsm.State();
      if(s == TS_ARCHIVED || s == TS_CANCELLED || s == TS_REJECTED) continue;
      kept[n++] = m_trades[i];
     }
   ArrayResize(kept, n);
   ArrayResize(m_trades, n);
   for(int i = 0; i < n; i++) m_trades[i] = kept[i];
  }
//+------------------------------------------------------------------+
// C003 FIX: closes the gap the audit flagged — a resting limit order
// (TS_PENDING, ticket = the ORDER ticket from PlaceLimit) that fills
// while the EA is running was previously invisible to PositionManager
// until the next Recovery() at restart, because nothing ever moved it to
// TS_FILLED or swapped its ticket over to the real POSITION ticket.
// Called from OnTradeTransaction() on TRADE_TRANSACTION_DEAL_ADD, the
// instant MT5 reports the fill — not polled, not deferred to restart.
// Market fills are unaffected: Submit() already transitions those to
// TS_FILLED synchronously in the same call that sends the order.
bool COrderManager::MarkFilledFromPending(ulong orderTicket, ulong positionTicket)
  {
   for(int i = 0; i < ArraySize(m_trades); i++)
     {
      if(m_trades[i].fsm.State() != TS_PENDING) continue;
      if(m_trades[i].fsm.Ticket() != orderTicket) continue;

      m_trades[i].fsm.SetTicket(positionTicket); // pending-order ticket -> live position ticket
      return m_trades[i].fsm.Transition(TS_FILLED);
     }
   return false; // no matching pending trade — not ours, or already handled
  }
//+------------------------------------------------------------------+
bool COrderManager::Submit(const TradeDecisionRecord &decision, double volume, bool useMarket, ulong &ticketOut)
  {
   ticketOut = 0;
   if(decision.action != POLICY_EXECUTE_ONLY && decision.action != POLICY_EXECUTE_AND_SIGNAL)
      return false;
   if(volume <= 0)
     {
      PrintFormat("MedisTouch OrderManager: decision #%d has non-positive volume, skipped", decision.decision_id);
      return false;
     }
   if(OpenCount() >= m_maxOpen)
     {
      PrintFormat("MedisTouch OrderManager: max open trades (%d) reached, decision #%d skipped",
                  m_maxOpen, decision.decision_id);
      return false;
     }
   if(FindByDecisionId(decision.decision_id) >= 0) return false; // already submitted, don't double-fire

   // Tag every order with its decision ID so a restarted terminal can
   // match a live position/pending order straight back to the exact
   // TradeDecisionRecord that created it, via CDecisionStore. This is
   // the entire matching key Recovery depends on.
   string tag = "MT#" + IntegerToString(decision.decision_id);

   int idx = ArraySize(m_trades);
   ArrayResize(m_trades, idx + 1);
   m_trades[idx].decision = decision;
   m_trades[idx].volume = volume;
   m_trades[idx].fsm.Start(decision.decision_id);
   m_trades[idx].fsm.BindMonitor(m_monitor);
   m_trades[idx].fsm.Transition(TS_VALIDATED);

   double entry = ResolveExecutionEntry(decision.setup); // Core/Config.mqh — same price ValidateSetup() gated against
   double sl = decision.setup.stop_loss;
   double tp = decision.setup.final_tp;
   ulong ticket = 0;
   bool ok = false;

   if(useMarket)
     {
      m_trades[idx].fsm.Transition(TS_PENDING);
      if(decision.setup.type == ORDER_TYPE_BUY)
         ok = m_broker.MarketBuy(decision.symbol, volume, sl, tp, ticket, tag);
      else
         ok = m_broker.MarketSell(decision.symbol, volume, sl, tp, ticket, tag);

      if(ok)
        {
         m_trades[idx].fsm.SetTicket(ticket);
         m_trades[idx].fsm.Transition(TS_FILLED);
        }
      else
         m_trades[idx].fsm.Transition(TS_REJECTED);
     }
   else
     {
      m_trades[idx].fsm.Transition(TS_WAITING);
      m_trades[idx].fsm.Transition(TS_PENDING);
      ENUM_ORDER_TYPE limitType = (decision.setup.type == ORDER_TYPE_BUY) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
      ok = m_broker.PlaceLimit(decision.symbol, limitType, volume, entry, sl, tp, ticket, tag);
      if(ok)
         m_trades[idx].fsm.SetTicket(ticket);
      else
         m_trades[idx].fsm.Transition(TS_REJECTED);
     }

   if(ok) ticketOut = ticket;
   return ok;
  }
//+------------------------------------------------------------------+
// RECOVERY ONLY — rebuilds a ManagedTrade from broker-side truth (an
// already-live position or pending order) instead of creating one via
// Submit()'s normal decide-then-execute path. No broker call happens
// here; the trade already exists at the broker, this just makes
// OrderManager's in-memory bookkeeping match it again after a restart.
bool COrderManager::RestoreTrade(const TradeDecisionRecord &decision, double volume, ulong ticket, ENUM_TRADE_STATE state)
  {
   if(FindByDecisionId(decision.decision_id) >= 0)
      return false; // already tracked this run — don't create a duplicate row

   int idx = ArraySize(m_trades);
   ArrayResize(m_trades, idx + 1);
   m_trades[idx].decision = decision;
   m_trades[idx].volume = volume;
   m_trades[idx].fsm.Start(decision.decision_id);
   m_trades[idx].fsm.BindMonitor(m_monitor);
   m_trades[idx].fsm.SetTicket(ticket);
   m_trades[idx].fsm.ForceState(state);
   return true;
  }
#endif
//+------------------------------------------------------------------+
