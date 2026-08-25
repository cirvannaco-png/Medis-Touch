//+------------------------------------------------------------------+
//|                                                   UI/Dashboard.mqh |
//+------------------------------------------------------------------+
#ifndef DASHBOARD_MQH
#define DASHBOARD_MQH

#include "../Core/Config.mqh"
#include "../Core/ObjectManager.mqh"
#include "../Analysis/TFContext.mqh"
#include "../Analysis/Scoring.mqh"
#include "../Trading/TradeZone.mqh"
#include "../Trading/OutcomeTracker.mqh"

class CDashboard
  {
private:
   CObjectManager*   m_objMan;
   CTFContext*       m_trendCtx;
   CTFContext*       m_bosCtx;
   CTFContext*       m_liqCtx;
   CScoringEngine*   m_scoring;
   CTradeDecision*   m_decision;
   COutcomeTracker*  m_tracker;
   string            m_symbol;

   string            TFLabel(ENUM_TIMEFRAMES tf);
   string            PhaseLabel(ENUM_MARKET_PHASE ph);
   string            FibZoneLabel(ENUM_FIB_ZONE z);
   string            VAZoneLabel(ENUM_VALUE_AREA_ZONE z);

public:
                     CDashboard();
   void              Init(CObjectManager* objMan, CTFContext* trendCtx, CTFContext* bosCtx, CTFContext* liqCtx,
                          CScoringEngine* scoring, CTradeDecision* decision, string symbol,
                          COutcomeTracker* tracker = NULL);
   void              Update();
  };
//+------------------------------------------------------------------+
CDashboard::CDashboard() : m_objMan(NULL), m_trendCtx(NULL), m_bosCtx(NULL), m_liqCtx(NULL),
                            m_scoring(NULL), m_decision(NULL), m_tracker(NULL) {}
void CDashboard::Init(CObjectManager* objMan, CTFContext* trendCtx, CTFContext* bosCtx, CTFContext* liqCtx,
                      CScoringEngine* scoring, CTradeDecision* decision, string symbol,
                      COutcomeTracker* tracker)
  {
   m_objMan = objMan;
   m_trendCtx = trendCtx;
   m_bosCtx = bosCtx;
   m_liqCtx = liqCtx;
   m_scoring = scoring;
   m_decision = decision;
   m_symbol = symbol;
   m_tracker = tracker;
  }
//+------------------------------------------------------------------+
string CDashboard::PhaseLabel(ENUM_MARKET_PHASE ph)
  {
   switch(ph)
     {
      case PHASE_ACCUMULATION: return "Accumulation";
      case PHASE_MANIPULATION: return "Manipulation";
      case PHASE_DISTRIBUTION: return "Distribution";
      default: return "Undefined";
     }
  }
//+------------------------------------------------------------------+
string CDashboard::FibZoneLabel(ENUM_FIB_ZONE z)
  {
   switch(z)
     {
      case FIB_ZONE_DISCOUNT: return "Discount";
      case FIB_ZONE_NEUTRAL:  return "Neutral";
      case FIB_ZONE_PREMIUM:  return "Premium";
      default:                return "Undefined";
     }
  }
//+------------------------------------------------------------------+
string CDashboard::VAZoneLabel(ENUM_VALUE_AREA_ZONE z)
  {
   switch(z)
     {
      case VA_ZONE_BELOW:  return "Below VA";
      case VA_ZONE_INSIDE: return "Inside VA";
      case VA_ZONE_ABOVE:  return "Above VA";
      default:             return "Undefined";
     }
  }
//+------------------------------------------------------------------+
string CDashboard::TFLabel(ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
  }
//+------------------------------------------------------------------+
void CDashboard::Update()
  {
   if(m_objMan == NULL) return;

   string trendStr = "Neutral";
   ENUM_TREND_STATE t = (m_trendCtx != NULL) ? m_trendCtx.trend.GetCurrentTrend() : TREND_NEUTRAL;
   switch(t)
     {
      case TREND_BULL_STRONG: trendStr = "Bullish (Strong)"; break;
      case TREND_BULL: trendStr = "Bullish"; break;
      case TREND_BEAR_STRONG: trendStr = "Bearish (Strong)"; break;
      case TREND_BEAR: trendStr = "Bearish"; break;
      default: trendStr = "Neutral"; break;
     }
   string trendTF = (m_trendCtx != NULL) ? TFLabel(m_trendCtx.tf) : "?";
   string bosTF = (m_bosCtx != NULL) ? TFLabel(m_bosCtx.tf) : "?";
   string liqTF = (m_liqCtx != NULL) ? TFLabel(m_liqCtx.tf) : "?";

   TradeSetup lastSetup;
   ZeroMemory(lastSetup);
   if(m_decision != NULL)
      lastSetup = m_decision.GetLastSetup();

   string text;
   if(lastSetup.active)
     {
      SetupReasons r = lastSetup.reasons;
      string dir = (lastSetup.type == ORDER_TYPE_BUY) ? "BUY SETUP" : "SELL SETUP";

      string reasonLines = "";
      if(r.inducement_valid) reasonLines += "\u2713 Inducement confirmed (sweep+BOS)\n";
      if(r.premium_discount_ok) reasonLines += "\u2713 Premium/Discount OK\n";
      reasonLines += StringFormat("  Phase: %s\n", PhaseLabel(r.phase));
      if(r.trend_aligned)   reasonLines += StringFormat("\u2713 %s trend aligned\n", trendTF);
      if(r.bos_confirmed)   reasonLines += StringFormat("\u2713 %s BOS/CHoCH confirmed\n", bosTF);
      if(r.liquidity_swept) reasonLines += StringFormat("\u2713 %s liquidity sweep\n", liqTF);
      if(r.fresh_fvg)       reasonLines += "\u2713 Fresh FVG in zone\n";
      if(r.sr_confluence)   reasonLines += "\u2713 S/R confluence\n";
      // v2.9: sweep grade / BOS strength / chase distance — the setup
      // grading breakdown from the review (items #16/#17), not just a
      // single confidence number.
      string gradeStr = (r.sweep_grade == SWEEP_GRADE_A) ? "A" : (r.sweep_grade == SWEEP_GRADE_B) ? "B" :
                         (r.sweep_grade == SWEEP_GRADE_C) ? "C" : "-";
      reasonLines += StringFormat("  Sweep grade: %s | BOS strength: %.0f%% | Decay: %.0f%%\n",
                                   gradeStr, r.bos_strength * 100.0, r.time_decay * 100.0);
      reasonLines += StringFormat("  Chase distance: %.2f ATR%s\n", r.chase_dist_atr, r.chase_ok ? "" : " \u26a0 late entry");
      reasonLines += StringFormat("  RVOL: %.2f%s\n", r.rvol, r.volume_confirmed ? " \u2713" : "");
      reasonLines += StringFormat("  Fib zone: %s%s\n", FibZoneLabel(r.fib_zone), r.fib_in_zone ? " \u2713 in pullback zone" : "");
      reasonLines += StringFormat("  Value Area: %s%s\n", VAZoneLabel(r.va_zone), r.value_area_ok ? " \u2713" : "");
      if(StringLen(reasonLines) == 0)
         reasonLines = "(no factors met threshold)\n";

      string riskLine = (StringLen(r.risk_warning) > 0) ? r.risk_warning : "None nearby";

      text = StringFormat(
                "MEDIS TOUCH \u2014 %s\n"
                "%s\n"
                "Confidence: %.0f%%\n"
                "\n"
                "Reasons:\n%s\n"
                "Risk:\n%s",
                m_symbol, dir, lastSetup.confidence, reasonLines, riskLine
             );
     }
   else
     {
      double confBuy = (m_scoring != NULL) ? m_scoring.CalculateConfidence(true) : 0.0;
      double confSell = (m_scoring != NULL) ? m_scoring.CalculateConfidence(false) : 0.0;
      string phaseStr = (m_scoring != NULL) ? PhaseLabel(m_scoring.GetPhase()) : "Undefined";
      text = StringFormat(
                "MEDIS TOUCH\n"
                "Symbol: %s\n"
                "%s Trend: %s\n"
                "Market Phase: %s\n"
                "Setup: None\n"
                "Buy conf: %.0f%% | Sell conf: %.0f%%",
                m_symbol, trendTF, trendStr, phaseStr, confBuy, confSell
             );
     }

   if(m_tracker != NULL)
     {
      OutcomeStats st = m_tracker.GetStats();
      double pf = st.ProfitFactor();
      string pfStr = (pf < 0) ? "\u221E" : DoubleToString(pf, 2); // -1 sentinel = infinite (no losing trades yet)
      text += StringFormat(
                "\n\n\u2014 Trade Simulator \u2014\n"
                "W:%d  L:%d  Scratch:%d  Ambig:%d\n"
                "Win rate (ex-ambig): %.1f%%\n"
                "Net P&L: %.2f | PF: %s\n"
                "Expectancy: %.2f/trade | Avg R: %.2f\n"
                "Costs — Comm: %.2f  Spread: %.2f  Slip: %.2f",
                st.wins, st.losses, st.scratches, st.ambiguous,
                st.WinRateExcludingAmbiguous(),
                st.netPnL, pfStr,
                st.ExpectancyPerTrade(), st.AverageRMultiple(),
                st.totalCommission, st.totalSpreadCost, st.totalSlippageCost
             );
     }

   m_objMan.CreateLabel("Dash_Info", 0, 0, text, clrWhite, 10);
   string full = m_objMan.NameOf("Dash_Info");
   ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, full, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, full, OBJPROP_YDISTANCE, 10);
  }
#endif
//+------------------------------------------------------------------+
