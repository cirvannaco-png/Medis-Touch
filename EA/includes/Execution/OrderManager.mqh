//+------------------------------------------------------------------+
//|                                        Execution/OrderManager.mqh |
//+------------------------------------------------------------------+
#ifndef ORDERMANAGER_MQH
#define ORDERMANAGER_MQH

#include "../Decision/TradeDecision.mqh"
#include "../Monitoring/LatencyTelemetry.mqh"
#include "TradeStateMachine.mqh"
#include "BrokerAdapter.mqh"

struct ManagedTrade
  {
   TradeDecisionRecord  decision;
   CTradeStateMachine   fsm;
   double               volume;
   double               fillPrice;
  };

class COrderManager
  {
private:
   CBrokerAdapter*     m_broker;
   ManagedTrade        m_trades[];
   int                 m_maxOpen;
   CProductionMonitor* m_monitor;
   int                 FindByDecisionId(long id);

public:
   void              Init(CBrokerAdapter* broker, int maxOpenTrades, CProductionMonitor* monitor);
   bool              Submit(const TradeDecisionRecord &decision, double volume, bool useMarket, double maxEntryDeviation, ulong &ticketOut);
   bool              RestoreTrade(const TradeDecisionRecord &decision, double volume, ulong ticket, ENUM_TRADE_STATE state);
   int               OpenCount();
   int               Total() { return ArraySize(m_trades); }
   void              Prune();
   bool              MarkFilledFromPending(ulong orderTicket, ulong positionTicket, double fillPrice = 0.0);

   ENUM_TRADE_STATE     StateAt(int idx)              { return m_trades[idx].fsm.State(); }
   ulong                TicketAt(int idx)              { return m_trades[idx].fsm.Ticket(); }
   TradeDecisionRecord  DecisionAt(int idx)            { return m_trades[idx].decision; }
   double               VolumeAt(int idx)              { return m_trades[idx].volume; }
   bool                 TransitionAt(int idx, ENUM_TRADE_STATE to) { return m_trades[idx].fsm.Transition(to); }
   double               FillPriceAt(int idx)
     {
      if(m_trades[idx].fillPrice > 0.0) return m_trades[idx].fillPrice;
      bool isBuy = (m_trades[idx].decision.setup.type == ORDER_TYPE_BUY);
      return isBuy ? m_trades[idx].decision.setup.entry_top : m_trades[idx].decision.setup.entry_bottom;
     }
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
bool COrderManager::MarkFilledFromPending(ulong orderTicket, ulong positionTicket, double fillPrice)
  {
   for(int i = 0; i < ArraySize(m_trades); i++)
     {
      if(m_trades[i].fsm.State() != TS_PENDING) continue;
      if(m_trades[i].fsm.Ticket() != orderTicket) continue;

      m_trades[i].fsm.SetTicket(positionTicket);
      if(fillPrice > 0.0) m_trades[i].fillPrice = fillPrice;
      bool filled = m_trades[i].fsm.Transition(TS_FILLED);
      if(filled)
        {
         if(g_latency.Active() && g_latency.DecisionId() == m_trades[i].decision.decision_id)
           {
            g_latency.MarkFillObserved();
            g_latency.Finalize(true);
           }
         if(m_monitor != NULL)
           {
            double totalMs = m_trades[i].fsm.TotalLatencyMs();
            if(totalMs >= 0.0) m_monitor.NotifyTradeLatency(totalMs, 0.0);
           }
        }
      return filled;
     }
   return false;
  }
//+------------------------------------------------------------------+
bool COrderManager::Submit(const TradeDecisionRecord &decision, double volume, bool useMarket, double maxEntryDeviation, ulong &ticketOut)
  {
   ticketOut = 0;
   if(decision.action != POLICY_EXECUTE_ONLY && decision.action != POLICY_EXECUTE_AND_SIGNAL) return false;
   if(volume <= 0)
     {
      PrintFormat("MedisTouch OrderManager: decision #%d has non-positive volume, skipped", decision.decision_id);
      return false;
     }
   if(OpenCount() >= m_maxOpen)
     {
      PrintFormat("MedisTouch OrderManager: max open trades (%d) reached, decision #%d skipped", m_maxOpen, decision.decision_id);
      return false;
     }
   if(FindByDecisionId(decision.decision_id) >= 0) return false;

   g_latency.MarkRisk(); // T4

   double entry = ResolveExecutionEntry(decision.setup);
   if(useMarket && maxEntryDeviation > 0.0)
     {
      MqlTick tick;
      if(SymbolInfoTick(decision.symbol, tick))
        {
         double marketPrice = (decision.setup.type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
         double deviation = MathAbs(marketPrice - entry);
         if(deviation > maxEntryDeviation)
           {
            PrintFormat("MedisTouch OrderManager: decision #%d rejected — market price %.5f drifted %.5f from decision entry %.5f (max %.5f). Signal is stale.",
                        decision.decision_id, marketPrice, deviation, entry, maxEntryDeviation);
            if(g_latency.Active() && g_latency.DecisionId() == decision.decision_id) g_latency.FinalizeRejected();
            return false;
           }
        }
     }

   string tag = "MT#" + IntegerToString(decision.decision_id);
   int idx = ArraySize(m_trades);
   ArrayResize(m_trades, idx + 1);
   m_trades[idx].decision = decision;
   m_trades[idx].volume = volume;
   m_trades[idx].fillPrice = 0.0;
   m_trades[idx].fsm.Start(decision.decision_id);
   m_trades[idx].fsm.BindMonitor(m_monitor);
   m_trades[idx].fsm.Transition(TS_VALIDATED);

   double sl = decision.setup.stop_loss;
   double tp = decision.setup.final_tp;
   ulong ticket = 0;
   double fillPrice = 0.0;
   bool ok = false;

   if(useMarket)
     {
      m_trades[idx].fsm.Transition(TS_PENDING);
      g_latency.MarkSubmission(); // T5: immediately before the broker request
      if(decision.setup.type == ORDER_TYPE_BUY)
         ok = m_broker.MarketBuy(decision.symbol, volume, sl, tp, ticket, fillPrice, tag);
      else
         ok = m_broker.MarketSell(decision.symbol, volume, sl, tp, ticket, fillPrice, tag);

      if(g_latency.Active() && g_latency.DecisionId() == decision.decision_id)
        {
         g_latency.MarkBrokerAck(); // T6
         if(ok)
           {
            g_latency.MarkFillObserved(); // T7: fill observed with the synchronous result
            g_latency.Finalize(true);
           }
         else
            g_latency.FinalizeRejected();
        }

      if(ok)
        {
         m_trades[idx].fsm.SetTicket(ticket);
         m_trades[idx].fsm.Transition(TS_FILLED);
         m_trades[idx].fillPrice = fillPrice;
         double slippage = fillPrice - entry;
         if(MathAbs(slippage) > 0.0)
            PrintFormat("MedisTouch OrderManager: decision #%d filled at %.5f (theoretical entry %.5f, slippage %.5f).",
                        decision.decision_id, fillPrice, entry, slippage);
         double totalMs = m_trades[idx].fsm.TotalLatencyMs();
         if(m_monitor != NULL && totalMs >= 0.0)
            m_monitor.NotifyTradeLatency(totalMs, m_broker.LastLatencyMs());
        }
      else
         m_trades[idx].fsm.Transition(TS_REJECTED);
     }
   else
     {
      m_trades[idx].fsm.Transition(TS_WAITING);
      m_trades[idx].fsm.Transition(TS_PENDING);
      ENUM_ORDER_TYPE limitType = (decision.setup.type == ORDER_TYPE_BUY) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
      g_latency.MarkSubmission(); // T5
      ok = m_broker.PlaceLimit(decision.symbol, limitType, volume, entry, sl, tp, ticket, tag);
      if(g_latency.Active() && g_latency.DecisionId() == decision.decision_id)
        {
         g_latency.MarkBrokerAck(); // T6
         g_latency.KeepPending();   // T7 is asynchronous
        }
      if(ok)
         m_trades[idx].fsm.SetTicket(ticket);
      else
        {
         m_trades[idx].fsm.Transition(TS_REJECTED);
         if(g_latency.Active() && g_latency.DecisionId() == decision.decision_id) g_latency.FinalizeRejected();
        }
     }

   if(ok) ticketOut = ticket;
   return ok;
  }
//+------------------------------------------------------------------+
bool COrderManager::RestoreTrade(const TradeDecisionRecord &decision, double volume, ulong ticket, ENUM_TRADE_STATE state)
  {
   if(FindByDecisionId(decision.decision_id) >= 0) return false;
   int idx = ArraySize(m_trades);
   ArrayResize(m_trades, idx + 1);
   m_trades[idx].decision = decision;
   m_trades[idx].volume = volume;
   m_trades[idx].fillPrice = 0.0;
   m_trades[idx].fsm.Start(decision.decision_id);
   m_trades[idx].fsm.BindMonitor(m_monitor);
   m_trades[idx].fsm.SetTicket(ticket);
   m_trades[idx].fsm.ForceState(state);
   return true;
  }
#endif
//+------------------------------------------------------------------+
