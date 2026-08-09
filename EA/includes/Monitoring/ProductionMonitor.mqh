//+------------------------------------------------------------------+
//|                                 Monitoring/ProductionMonitor.mqh |
//+------------------------------------------------------------------+
#ifndef PRODUCTIONMONITOR_MQH
#define PRODUCTIONMONITOR_MQH

// Lightweight health surface for running unattended. This is NOT a
// dashboard — it has no UI of its own. It writes a heartbeat file an
// external watchdog (cron job, VPS monitor, whatever you already use)
// can tail to detect the EA going silent, and logs terminal warnings
// when the account itself starts showing signs of trouble. Deliberately
// simple: no alerting integrations (email/Telegram/etc.), since those
// each need their own credentials and are a natural layer ON TOP of
// this, not inside it — same anti-complexity rule as the rest of this
// codebase.
class CProductionMonitor
  {
private:
   string            m_heartbeatFile;
   string            m_symbol;
   datetime          m_startTime;
   datetime          m_lastHeartbeat;
   int               m_heartbeatIntervalSec;

   int               m_brokerRejectCount;
   int               m_illegalTransitionCount;
   double            m_peakEquity;
   double            m_maxDrawdownAlertPercent;
   bool              m_drawdownAlertFired;

public:
   void              Init(string symbol, int heartbeatIntervalSec, double maxDrawdownAlertPercent);
   void              OnTickCheck();             // call once per OnTick — cheap, cadence-gated internally
   void              NotifyBrokerReject();       // call when Submit()/BrokerAdapter reports a failed order
   void              NotifyIllegalTransition();  // hook for CTradeStateMachine's illegal-transition log — see note below
   string            StatusSummary();
  };
//+------------------------------------------------------------------+
void CProductionMonitor::Init(string symbol, int heartbeatIntervalSec, double maxDrawdownAlertPercent)
  {
   m_symbol = symbol;
   m_heartbeatFile = "MedisTouch_Heartbeat_" + symbol + ".txt";
   m_startTime = TimeCurrent();
   m_lastHeartbeat = 0;
   m_heartbeatIntervalSec = heartbeatIntervalSec;
   m_brokerRejectCount = 0;
   m_illegalTransitionCount = 0;
   m_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   m_maxDrawdownAlertPercent = maxDrawdownAlertPercent;
   m_drawdownAlertFired = false;
  }
//+------------------------------------------------------------------+
void CProductionMonitor::NotifyBrokerReject() { m_brokerRejectCount++; }
//+------------------------------------------------------------------+
// C004 FIX: previously dead — nothing called this. CTradeStateMachine now
// holds a CProductionMonitor* (bound via BindMonitor(), see
// Execution/TradeStateMachine.mqh) and calls this from Transition() itself
// whenever IsLegal() rejects a move, instead of only Print()-ing it where
// no external watchdog can see. COrderManager binds every ManagedTrade's
// fsm to this monitor right after construction, in both Submit() and
// RestoreTrade().
void CProductionMonitor::NotifyIllegalTransition() { m_illegalTransitionCount++; }
//+------------------------------------------------------------------+
void CProductionMonitor::OnTickCheck()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > m_peakEquity) m_peakEquity = equity;

   double drawdownPercent = (m_peakEquity > 0) ? (m_peakEquity - equity) / m_peakEquity * 100.0 : 0.0;
   if(drawdownPercent >= m_maxDrawdownAlertPercent && !m_drawdownAlertFired)
     {
      PrintFormat("MedisTouch Monitor: ALERT — drawdown from peak equity is %.2f%%, at or past the %.2f%% alert threshold.",
                  drawdownPercent, m_maxDrawdownAlertPercent);
      m_drawdownAlertFired = true;
     }
   else if(drawdownPercent < m_maxDrawdownAlertPercent * 0.5 && m_drawdownAlertFired)
      m_drawdownAlertFired = false; // recovered well clear of the threshold — allow the alert to fire again if it recurs

   datetime now = TimeCurrent();
   if(now - m_lastHeartbeat < m_heartbeatIntervalSec) return;
   m_lastHeartbeat = now;

   int handle = FileOpen(m_heartbeatFile, FILE_WRITE | FILE_TXT);
   if(handle == INVALID_HANDLE) return;
   FileWriteString(handle, StringFormat(
      "symbol=%s\nlast_heartbeat=%s\nuptime_sec=%d\nequity=%.2f\npeak_equity=%.2f\ndrawdown_pct=%.2f\n"
      "broker_rejects=%d\nillegal_transitions=%d\n",
      m_symbol, TimeToString(now, TIME_DATE | TIME_SECONDS), (int)(now - m_startTime),
      equity, m_peakEquity, drawdownPercent, m_brokerRejectCount, m_illegalTransitionCount));
   FileClose(handle);
  }
//+------------------------------------------------------------------+
string CProductionMonitor::StatusSummary()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdownPercent = (m_peakEquity > 0) ? (m_peakEquity - equity) / m_peakEquity * 100.0 : 0.0;
   return StringFormat("MedisTouch [%s] uptime=%ds equity=%.2f drawdown=%.2f%% rejects=%d illegalTransitions=%d",
                       m_symbol, (int)(TimeCurrent() - m_startTime), equity, drawdownPercent,
                       m_brokerRejectCount, m_illegalTransitionCount);
  }
#endif
//+------------------------------------------------------------------+
