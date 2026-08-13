//+------------------------------------------------------------------+
//|                                        Portfolio/RiskGuard.mqh    |
//+------------------------------------------------------------------+
#ifndef RISKGUARD_MQH
#define RISKGUARD_MQH

// Account-level circuit breaker, evaluated once per tick (cheap — just
// reads AccountInfoDouble) BEFORE any new decision is even generated.
// This is the honest version of "consistency tuning": it does not
// suppress winning days to flatten an equity curve for a prop-firm
// evaluator, and it does not hide anything from anyone. It does two
// things, both disclosed in the terminal log when they trigger:
//
//   1. DAILY LOSS CAP — once today's realized+floating loss from the
//      day's starting equity exceeds InpMaxDailyLossPercent, no new
//      trades until the next trading day (broker/server time). Existing
//      open positions are left alone — this blocks NEW risk, it does not
//      panic-close what's already open (that's a separate, deliberate
//      decision your position management already owns via SL/trailing).
//   2. DRAWDOWN DE-RISK RAMP — as floating drawdown from the account's
//      peak equity grows past a soft threshold, position size for any
//      NEW trade is linearly reduced (down to a floor, never to zero via
//      this mechanism alone — the hard drawdown cap below does that).
//      This is ordinary risk-of-ruin management: size down when you're
//      already underwater, same as a fixed-fractional system does
//      naturally, just made explicit and configurable instead of
//      implicit in equity-based position sizing alone.
//   3. HARD DRAWDOWN CAP — beyond InpMaxDrawdownPercent from peak
//      equity, trading halts entirely until you manually clear it
//      (IsHalted() stays true across restarts — see Persist()/Restore()
//      — a real drawdown breach shouldn't quietly clear itself just
//      because the terminal restarted).
class CRiskGuard
  {
private:
   double   m_maxDailyLossPercent;
   double   m_maxDrawdownPercent;
   double   m_deriskStartPercent;   // drawdown %, from peak, where size reduction begins
   double   m_deriskFloor;          // minimum size multiplier the ramp can reach (e.g. 0.25 = never below 25%)

   double   m_dayStartEquity;
   int      m_dayStartDayOfYear;
   int      m_dayStartYear;

   double   m_peakEquity;
   bool     m_hardHalted;

   string   m_gvPeakKey;
   string   m_gvHaltedKey;

   void     RolloverIfNewDay();

public:
   void     Init(string symbol, double maxDailyLossPercent, double maxDrawdownPercent,
                  double deriskStartPercent, double deriskFloor);
   void     OnTick(); // cheap — call every tick, same cadence as CProductionMonitor::OnTickCheck()

   bool     IsDailyLossLimitHit(string &reasonOut);
   bool     IsHardHalted(string &reasonOut);
   double   SizeMultiplier(); // 1.0 normal, ramps down between m_deriskStartPercent and m_maxDrawdownPercent
   double   CurrentDrawdownPercent();

   void     ManualReset(); // explicit operator action to clear a hard halt — never automatic
  };
//+------------------------------------------------------------------+
void CRiskGuard::Init(string symbol, double maxDailyLossPercent, double maxDrawdownPercent,
                       double deriskStartPercent, double deriskFloor)
  {
   m_maxDailyLossPercent = maxDailyLossPercent;
   m_maxDrawdownPercent = maxDrawdownPercent;
   m_deriskStartPercent = deriskStartPercent;
   m_deriskFloor = MathMax(0.05, MathMin(1.0, deriskFloor));

   m_gvPeakKey = "MedisTouch_PeakEquity_" + symbol;
   m_gvHaltedKey = "MedisTouch_HardHalted_" + symbol;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   // Persisted peak survives terminal restarts (GlobalVariables live in
   // the terminal, not this EA instance) — a restart should never quietly
   // reset "how far underwater are we from the real high-water mark".
   if(GlobalVariableCheck(m_gvPeakKey))
      m_peakEquity = MathMax(GlobalVariableGet(m_gvPeakKey), equity);
   else
      m_peakEquity = equity;
   GlobalVariableSet(m_gvPeakKey, m_peakEquity);

   m_hardHalted = GlobalVariableCheck(m_gvHaltedKey) && (GlobalVariableGet(m_gvHaltedKey) > 0.5);

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   m_dayStartYear = t.year;
   m_dayStartDayOfYear = t.day_of_year;
   m_dayStartEquity = equity;
  }
//+------------------------------------------------------------------+
void CRiskGuard::RolloverIfNewDay()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(t.year != m_dayStartYear || t.day_of_year != m_dayStartDayOfYear)
     {
      m_dayStartYear = t.year;
      m_dayStartDayOfYear = t.day_of_year;
      m_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      PrintFormat("MedisTouch RiskGuard: new trading day, daily loss cap reset (start equity %.2f)", m_dayStartEquity);
     }
  }
//+------------------------------------------------------------------+
void CRiskGuard::OnTick()
  {
   RolloverIfNewDay();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > m_peakEquity)
     {
      m_peakEquity = equity;
      GlobalVariableSet(m_gvPeakKey, m_peakEquity);
     }

   if(!m_hardHalted && m_maxDrawdownPercent > 0 && CurrentDrawdownPercent() >= m_maxDrawdownPercent)
     {
      m_hardHalted = true;
      GlobalVariableSet(m_gvHaltedKey, 1.0);
      PrintFormat("MedisTouch RiskGuard: HARD HALT — drawdown from peak equity (%.2f) reached %.2f%%, at/above the %.2f%% cap. No new trades until ManualReset().",
                  m_peakEquity, CurrentDrawdownPercent(), m_maxDrawdownPercent);
     }
  }
//+------------------------------------------------------------------+
double CRiskGuard::CurrentDrawdownPercent()
  {
   if(m_peakEquity <= 0) return 0.0;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return MathMax(0.0, (m_peakEquity - equity) / m_peakEquity * 100.0);
  }
//+------------------------------------------------------------------+
bool CRiskGuard::IsDailyLossLimitHit(string &reasonOut)
  {
   reasonOut = "";
   if(m_maxDailyLossPercent <= 0 || m_dayStartEquity <= 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = MathMax(0.0, (m_dayStartEquity - equity) / m_dayStartEquity * 100.0);
   if(lossPercent >= m_maxDailyLossPercent)
     {
      reasonOut = StringFormat("daily loss cap hit: down %.2f%% from today's start equity %.2f (cap %.2f%%)",
                                lossPercent, m_dayStartEquity, m_maxDailyLossPercent);
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
bool CRiskGuard::IsHardHalted(string &reasonOut)
  {
   reasonOut = "";
   if(!m_hardHalted) return false;
   reasonOut = StringFormat("hard drawdown halt active — %.2f%% below peak equity %.2f (cap %.2f%%). Call ManualReset() to clear after reviewing why.",
                             CurrentDrawdownPercent(), m_peakEquity, m_maxDrawdownPercent);
   return true;
  }
//+------------------------------------------------------------------+
// Linear ramp: 1.0 at/below m_deriskStartPercent drawdown, down to
// m_deriskFloor at m_maxDrawdownPercent drawdown (where the hard halt
// takes over anyway). Sizing down while already underwater is standard
// risk-of-ruin discipline — smaller bets while you're proving the
// strategy still works, not smaller REPORTED profit to fool anyone.
double CRiskGuard::SizeMultiplier()
  {
   if(m_maxDrawdownPercent <= m_deriskStartPercent) return 1.0; // misconfigured — fail to "no reduction" rather than divide by ~0
   double dd = CurrentDrawdownPercent();
   if(dd <= m_deriskStartPercent) return 1.0;
   if(dd >= m_maxDrawdownPercent) return m_deriskFloor;
   double span = m_maxDrawdownPercent - m_deriskStartPercent;
   double progress = (dd - m_deriskStartPercent) / span;
   return 1.0 - progress * (1.0 - m_deriskFloor);
  }
//+------------------------------------------------------------------+
void CRiskGuard::ManualReset()
  {
   m_hardHalted = false;
   GlobalVariableSet(m_gvHaltedKey, 0.0);
   PrintFormat("MedisTouch RiskGuard: hard halt manually cleared by operator.");
  }
#endif
//+------------------------------------------------------------------+
