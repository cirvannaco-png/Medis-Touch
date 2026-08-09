//+------------------------------------------------------------------+
//|                                        Recovery/RecoveryEngine.mqh |
//+------------------------------------------------------------------+
#ifndef RECOVERYENGINE_MQH
#define RECOVERYENGINE_MQH

#include "../Decision/DecisionStore.mqh"
#include "../Execution/OrderManager.mqh"
#include "../Execution/TradeStateMachine.mqh"

// Runs once, at OnInit, after every other manager is constructed. An MT5
// restart (terminal crash, VPS reboot, manual restart, a broker server
// bounce) does not touch open positions or pending orders at the broker
// — only this EA's in-memory bookkeeping (COrderManager's array, each
// trade's state machine) is lost. Without this, a restarted EA either
// treats a live position as unknown and never manages it again (no
// break-even, no partial, no trailing — it just sits there), or worse,
// re-decides the same setup and doubles up.
//
// Matching key: the order comment set at submission time, "MT#<decision
// id>" (see OrderManager::Submit / BrokerAdapter). Every live position
// and pending order under this EA's magic number+symbol is inspected;
// its comment is parsed back to a decision ID, looked up in
// CDecisionStore for the full original setup, cross-referenced against
// the executions log for the volume actually submitted, and pushed back
// into COrderManager via RestoreTrade().
//
// State inference on restore is deliberately conservative. Which of
// FILLED / PROTECTED / PARTIAL / RUNNER a position currently sits in
// isn't recorded anywhere broker-side, so this infers it from what the
// broker DOES expose:
//   - current SL vs. the recorded entry price -> break-even taken or not
//   - current position volume vs. the originally submitted volume ->
//     partial taken or not
// This can't distinguish every edge case perfectly (e.g. a manually
// moved SL that happens to sit at breakeven), but it never invents a
// MORE advanced state than the evidence supports — PositionManager's own
// per-tick logic then just continues driving the trade forward from
// wherever it actually is. That's the safe direction to be wrong in.
class CRecoveryEngine
  {
private:
   CDecisionStore*   m_store;
   COrderManager*    m_orders;
   ulong             m_magic;
   string            m_symbol;

   bool              ParseDecisionId(string comment, long &idOut);
   ENUM_TRADE_STATE  InferPositionState(double submittedVolume, double currentVolume,
                                        double entryPrice, double currentSL, bool isBuy);

public:
   void              Init(CDecisionStore* store, COrderManager* orders, ulong magic, string symbol);
   int               Recover(); // returns count of trades restored
  };
//+------------------------------------------------------------------+
void CRecoveryEngine::Init(CDecisionStore* store, COrderManager* orders, ulong magic, string symbol)
  {
   m_store = store;
   m_orders = orders;
   m_magic = magic;
   m_symbol = symbol;
  }
//+------------------------------------------------------------------+
bool CRecoveryEngine::ParseDecisionId(string comment, long &idOut)
  {
   idOut = 0;
   if(StringSubstr(comment, 0, 3) != "MT#") return false;
   string numPart = StringSubstr(comment, 3);
   if(StringLen(numPart) == 0) return false;
   idOut = (long)StringToInteger(numPart);
   return idOut > 0;
  }
//+------------------------------------------------------------------+
ENUM_TRADE_STATE CRecoveryEngine::InferPositionState(double submittedVolume, double currentVolume,
                                                     double entryPrice, double currentSL, bool isBuy)
  {
   bool partialTaken = (submittedVolume > 0 && currentVolume < submittedVolume - 0.0000001);

   bool atOrPastBreakEven = isBuy ? (currentSL >= entryPrice - 0.0000001)
                                  : (currentSL <= entryPrice + 0.0000001);
   if(currentSL == 0) atOrPastBreakEven = false; // no stop set at all — don't misread that as "at break-even"

   if(partialTaken) return TS_RUNNER;       // partial only ever fires from PROTECTED in this EA's own flow
   if(atOrPastBreakEven) return TS_PROTECTED;
   return TS_FILLED;
  }
//+------------------------------------------------------------------+
int CRecoveryEngine::Recover()
  {
   int restored = 0;

   // --- Open positions ---
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic) continue;

      long decisionId;
      if(!ParseDecisionId(PositionGetString(POSITION_COMMENT), decisionId))
        {
         PrintFormat("MedisTouch Recovery: open position #%I64u under our magic number has no MT# comment — not ours to manage, skipping.",
                     ticket);
         continue;
        }

      TradeDecisionRecord dec;
      if(!m_store.FindById(decisionId, dec))
        {
         PrintFormat("MedisTouch Recovery: position #%I64u references decision #%d, not found in the decision store — cannot restore, skipping.",
                     ticket, decisionId);
         continue;
        }

      ExecutionRecord execs[];
      int execCount = m_store.LoadAllExecutions(execs);
      double currentVolume = PositionGetDouble(POSITION_VOLUME);
      double submittedVolume = currentVolume; // fallback if no execution row was ever written
      for(int e = 0; e < execCount; e++)
         if(execs[e].decision_id == decisionId)
           {
            submittedVolume = execs[e].volume;
            break;
           }

      bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
      double entry = isBuy ? dec.setup.entry_top : dec.setup.entry_bottom;
      double currentSL = PositionGetDouble(POSITION_SL);

      ENUM_TRADE_STATE state = InferPositionState(submittedVolume, currentVolume, entry, currentSL, isBuy);

      if(m_orders.RestoreTrade(dec, currentVolume, ticket, state))
        {
         restored++;
         PrintFormat("MedisTouch Recovery: restored decision #%d as ticket #%I64u in state %s.",
                     decisionId, ticket, TradeStateToString(state));
        }
     }

   // --- Pending (resting limit) orders ---
   for(int i = 0; i < OrdersTotal(); i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != m_symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != m_magic) continue;

      long decisionId;
      if(!ParseDecisionId(OrderGetString(ORDER_COMMENT), decisionId)) continue;

      TradeDecisionRecord dec;
      if(!m_store.FindById(decisionId, dec))
        {
         PrintFormat("MedisTouch Recovery: pending order #%I64u references decision #%d, not found in the decision store — cannot restore, skipping.",
                     ticket, decisionId);
         continue;
        }

      double vol = OrderGetDouble(ORDER_VOLUME_CURRENT);
      if(m_orders.RestoreTrade(dec, vol, ticket, TS_PENDING))
        {
         restored++;
         PrintFormat("MedisTouch Recovery: restored decision #%d as pending order #%I64u.", decisionId, ticket);
        }
     }

   return restored;
  }
#endif
//+------------------------------------------------------------------+
