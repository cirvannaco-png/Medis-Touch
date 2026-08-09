//+------------------------------------------------------------------+
//|                                  Execution/TradeStateMachine.mqh |
//+------------------------------------------------------------------+
#ifndef TRADESTATEMACHINE_MQH
#define TRADESTATEMACHINE_MQH

#include "../Monitoring/ProductionMonitor.mqh"

enum ENUM_TRADE_STATE
  {
   TS_DETECTED,   // setup produced by analysis, not yet routed through the Decision Engine
   TS_VALIDATED,  // Policy Engine approved execution
   TS_WAITING,    // approved, waiting for price to reach the entry zone (pending-order path)
   TS_PENDING,    // order sent to the broker, not yet filled
   TS_FILLED,     // position open, still at original SL/TP
   TS_PROTECTED,  // stop moved to break-even
   TS_PARTIAL,    // partial close taken at TP1
   TS_RUNNER,     // remainder trailing toward final_tp
   TS_CLOSED,     // position fully closed (SL, TP, trail, or manual)
   TS_ARCHIVED,   // closed trade written to the journal, no longer polled
   TS_CANCELLED,  // pending order cancelled or setup invalidated before fill
   TS_REJECTED    // broker rejected the order
  };
//+------------------------------------------------------------------+
string TradeStateToString(ENUM_TRADE_STATE s)
  {
   switch(s)
     {
      case TS_DETECTED:  return "Detected";
      case TS_VALIDATED: return "Validated";
      case TS_WAITING:   return "Waiting";
      case TS_PENDING:   return "Pending";
      case TS_FILLED:    return "Filled";
      case TS_PROTECTED: return "Protected";
      case TS_PARTIAL:   return "Partial";
      case TS_RUNNER:    return "Runner";
      case TS_CLOSED:    return "Closed";
      case TS_ARCHIVED:  return "Archived";
      case TS_CANCELLED: return "Cancelled";
      case TS_REJECTED:  return "Rejected";
     }
   return "Unknown";
  }
//+------------------------------------------------------------------+
// One instance per live trade, from decision through archive. Every state
// change goes through Transition(), which enforces the legal-move table
// below instead of six different call sites setting a flag directly and
// silently drifting out of sync with each other.
class CTradeStateMachine
  {
private:
   ENUM_TRADE_STATE  m_state;
   long              m_decisionId;
   ulong             m_ticket;      // order/position ticket, once one exists
   datetime          m_lastChange;
   CProductionMonitor* m_monitor;   // C004 FIX: was permanently NULL — nothing ever bound one. See BindMonitor().

   bool              IsLegal(ENUM_TRADE_STATE from, ENUM_TRADE_STATE to);

public:
                     CTradeStateMachine();
   void              Start(long decisionId);
   // C004 FIX: this used to be a dead hook — CProductionMonitor::NotifyIllegalTransition()
   // existed and worked, but no CTradeStateMachine instance ever held a reference to call
   // it with, since each one is default-constructed inside the ManagedTrade array (Submit()/
   // RestoreTrade() in OrderManager.mqh) with no monitor available at construction time.
   // BindMonitor() is the mechanical fix the audit called out: call it once right after
   // Start(), from every place a ManagedTrade is created, and illegal transitions start
   // actually incrementing the monitor's counter and showing up in the heartbeat file
   // instead of only ever reaching a Print() no external watchdog can see.
   void              BindMonitor(CProductionMonitor *monitor) { m_monitor = monitor; }
   bool              Transition(ENUM_TRADE_STATE to);
   void              ForceState(ENUM_TRADE_STATE to); // RECOVERY ONLY — bypasses IsLegal(). Recovery reconstructs
                                                        // state from broker-side evidence (position SL vs entry,
                                                        // current volume vs submitted volume), not from a live
                                                        // decision walking through its normal sequence — so there is
                                                        // no "from" state to validate a transition against. Anything
                                                        // other than Recovery calling this defeats the entire point
                                                        // of the legal-transition table above.
   ENUM_TRADE_STATE  State() const { return m_state; }
   long              DecisionId() const { return m_decisionId; }
   void              SetTicket(ulong ticket) { m_ticket = ticket; }
   ulong             Ticket() const { return m_ticket; }
   datetime          LastChange() const { return m_lastChange; }
  };
//+------------------------------------------------------------------+
CTradeStateMachine::CTradeStateMachine()
  {
   m_state = TS_DETECTED;
   m_decisionId = 0;
   m_ticket = 0;
   m_lastChange = 0;
   m_monitor = NULL;
  }
//+------------------------------------------------------------------+
void CTradeStateMachine::Start(long decisionId)
  {
   m_decisionId = decisionId;
   m_state = TS_DETECTED;
   m_ticket = 0;
   m_lastChange = TimeCurrent();
  }
//+------------------------------------------------------------------+
bool CTradeStateMachine::IsLegal(ENUM_TRADE_STATE from, ENUM_TRADE_STATE to)
  {
   switch(from)
     {
      case TS_DETECTED:  return (to == TS_VALIDATED || to == TS_CANCELLED);
      case TS_VALIDATED: return (to == TS_WAITING || to == TS_PENDING || to == TS_CANCELLED);
      case TS_WAITING:   return (to == TS_PENDING || to == TS_CANCELLED);
      case TS_PENDING:   return (to == TS_FILLED || to == TS_CANCELLED || to == TS_REJECTED);
      case TS_FILLED:    return (to == TS_PROTECTED || to == TS_PARTIAL || to == TS_CLOSED);
      case TS_PROTECTED: return (to == TS_PARTIAL || to == TS_CLOSED);
      case TS_PARTIAL:   return (to == TS_RUNNER || to == TS_CLOSED);
      case TS_RUNNER:    return (to == TS_CLOSED);
      case TS_CLOSED:    return (to == TS_ARCHIVED);
      default:           return false; // ARCHIVED / CANCELLED / REJECTED are terminal
     }
  }
//+------------------------------------------------------------------+
bool CTradeStateMachine::Transition(ENUM_TRADE_STATE to)
  {
   if(!IsLegal(m_state, to))
     {
      PrintFormat("MedisTouch StateMachine: illegal transition %s -> %s (decision #%d)",
                  TradeStateToString(m_state), TradeStateToString(to), m_decisionId);
      if(m_monitor != NULL) m_monitor.NotifyIllegalTransition();
      return false;
     }
   m_state = to;
   m_lastChange = TimeCurrent();
   return true;
  }
//+------------------------------------------------------------------+
void CTradeStateMachine::ForceState(ENUM_TRADE_STATE to)
  {
   PrintFormat("MedisTouch StateMachine: recovery force-state %s -> %s (decision #%d) — bypassing legality check",
               TradeStateToString(m_state), TradeStateToString(to), m_decisionId);
   m_state = to;
   m_lastChange = TimeCurrent();
  }
#endif
//+------------------------------------------------------------------+
