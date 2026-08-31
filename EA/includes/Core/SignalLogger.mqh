//+------------------------------------------------------------------+
//|                                          Core/SignalLogger.mqh    |
//+------------------------------------------------------------------+
#ifndef SIGNALLOGGER_MQH
#define SIGNALLOGGER_MQH

#include "Config.mqh"

// Session labeling: v4 bucketed by raw server-clock hour, which drifts
// wrong by however many hours the broker's server sits from GMT (and
// worse across DST changes). This version computes the live server-to-GMT
// offset via TimeTradeServer()/TimeGMT() and buckets by real GMT session
// windows (Sydney/Tokyo/London/New York + overlaps) instead.
class CSignalLogger
  {
private:
   string            m_filename;
   string            m_outcomeFilename;
   bool              m_headerWritten;
   bool              m_outcomeHeaderWritten;
   int               m_gmtOffsetOverrideHours; // 999 = auto-detect

   string            SessionForGMTHour(int h);
   int               ServerToGMTOffsetHours();
   string            SessionLabel(datetime serverTime);
   string            ReasonString(SetupReasons &r);
   string            FillPolicyLabel(ENUM_FILL_POLICY fp);
   string            FibZoneLabel(ENUM_FIB_ZONE z);
   string            VAZoneLabel(ENUM_VALUE_AREA_ZONE z);
   string            VolRegimeLabel(ENUM_VOL_REGIME v);
   string            OBStateLabel(ENUM_OB_STATE s);
   string            RegimeLabel(ENUM_MARKET_REGIME r);       // v2.12
   string            BreakoutClassLabel(ENUM_BREAKOUT_CLASS c); // v2.12
   string            ReversionClassLabel(ENUM_REVERSION_CLASS c); // v2.13
   string            KeyLevelSourceLabel(ENUM_KEYLEVEL_SOURCE s);     // v2.14
   string            KeyLevelReactionLabel(ENUM_KEYLEVEL_REACTION r); // v2.14
   string            SelectedStrategyLabel(ENUM_SELECTED_STRATEGY s); // v2.15

public:
                     CSignalLogger();
   void              Init(string symbol, int gmtOffsetOverrideHours = 999);
   bool              LogSetup(TradeSetup &setup, string symbol, ENUM_TIMEFRAMES entryTF, string trendLabel);
   bool              LogOutcome(PendingSetup &p, string symbol, ENUM_TIMEFRAMES entryTF, string outcome,
                                double exitPrice, ENUM_FILL_POLICY fillPolicy = FILL_CONSERVATIVE);
  };
//+------------------------------------------------------------------+
CSignalLogger::CSignalLogger() : m_headerWritten(false), m_outcomeHeaderWritten(false), m_gmtOffsetOverrideHours(999) {}
//+------------------------------------------------------------------+
void CSignalLogger::Init(string symbol, int gmtOffsetOverrideHours)
  {
   m_filename = "MedisTouch_Signals_" + symbol + ".csv";
   m_outcomeFilename = "MedisTouch_Outcomes_" + symbol + ".csv";
   m_headerWritten = FileIsExist(m_filename);
   m_outcomeHeaderWritten = FileIsExist(m_outcomeFilename);
   m_gmtOffsetOverrideHours = gmtOffsetOverrideHours;
  }
//+------------------------------------------------------------------+
// FIX: v4 used the raw server hour as a proxy for session, which is only
// correct if the broker's server clock happens to run on GMT — most
// don't (common offsets are GMT+2/+3, sometimes with their own DST
// schedule that doesn't match any real session's DST). This computes the
// actual live offset each call via TimeTradeServer() - TimeGMT(), so it
// self-corrects across DST transitions instead of drifting for months.
//
// CAVEAT: TimeGMT() depends on the terminal's Windows GMT/timezone
// database being current, and can behave inconsistently inside the
// Strategy Tester on some builds. InpSessionGMTOffsetOverride exists
// specifically so you can pin a known-correct offset if you ever see the
// auto-detected value look wrong for your broker.
int CSignalLogger::ServerToGMTOffsetHours()
  {
   if(m_gmtOffsetOverrideHours != 999)
      return m_gmtOffsetOverrideHours;
   datetime srv = TimeTradeServer();
   datetime gmt = TimeGMT();
   double hours = (double)(srv - gmt) / 3600.0;
   return (int)MathRound(hours);
  }
//+------------------------------------------------------------------+
string CSignalLogger::SessionForGMTHour(int h)
  {
   h = ((h % 24) + 24) % 24; // normalize
   bool sydney = (h >= 21 || h < 6);
   bool tokyo  = (h >= 0  && h < 9);
   bool london = (h >= 7  && h < 16);
   bool ny     = (h >= 12 && h < 21);

   if(london && ny)    return "London/NY Overlap";
   if(tokyo && london) return "Tokyo/London Overlap";
   if(sydney && tokyo) return "Sydney/Tokyo Overlap";
   if(london) return "London";
   if(ny)     return "New York";
   if(tokyo)  return "Tokyo";
   if(sydney) return "Sydney";
   return "Off-hours";
  }
//+------------------------------------------------------------------+
string CSignalLogger::SessionLabel(datetime serverTime)
  {
   int offset = ServerToGMTOffsetHours();
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   int gmtHour = dt.hour - offset;
   return SessionForGMTHour(gmtHour);
  }
//+------------------------------------------------------------------+
string CSignalLogger::ReasonString(SetupReasons &r)
  {
   string s = "";
   if(r.trend_aligned)   s += "Trend|";
   if(r.bos_confirmed)   s += "BOS|";
   if(r.liquidity_swept) s += "Liquidity|";
   if(r.fresh_fvg)       s += "FVG|";
   if(r.sr_confluence)   s += "SR|";
   if(r.inducement_valid) s += "Inducement|";
   if(r.premium_discount_ok) s += "PremDisc|";
   if(r.volume_confirmed) s += "Volume|";
   if(r.fib_in_zone) s += "FibZone|";
   if(r.value_area_ok) s += "ValueArea|";
   if(r.htf_ob_confluence) s += "HtfOB|";
   if(!r.session_ok) s += "OffSession|";
   if(StringLen(s) == 0) return "None";
   return s;
  }
//+------------------------------------------------------------------+
string CSignalLogger::VolRegimeLabel(ENUM_VOL_REGIME v)
  {
   switch(v)
     {
      case VOL_REGIME_LOW:    return "Low";
      case VOL_REGIME_NORMAL: return "Normal";
      case VOL_REGIME_HIGH:   return "High";
      default:                return "Undefined";
     }
  }
//+------------------------------------------------------------------+
string CSignalLogger::OBStateLabel(ENUM_OB_STATE s)
  {
   switch(s)
     {
      case OB_FRESH:     return "Fresh";
      case OB_TESTED:     return "Tested";
      case OB_MITIGATED:  return "Mitigated";
      default:            return "None";
     }
  }
//+------------------------------------------------------------------+
// v2.12
string CSignalLogger::RegimeLabel(ENUM_MARKET_REGIME r)
  {
   switch(r)
     {
      case REGIME_TRENDING:    return "Trending";
      case REGIME_RANGING:     return "Ranging";
      case REGIME_TRANSITION:  return "Transition";
      default:                 return "Undefined";
     }
  }
//+------------------------------------------------------------------+
// v2.12
string CSignalLogger::BreakoutClassLabel(ENUM_BREAKOUT_CLASS c)
  {
   switch(c)
     {
      case BREAKOUT_EXPANSION:  return "Expansion";
      case BREAKOUT_LIQUIDITY:  return "Liquidity";
      case BREAKOUT_FAILED:     return "Failed";
      case BREAKOUT_EXHAUSTION: return "Exhaustion";
      default:                  return "None";
     }
  }
//+------------------------------------------------------------------+
// v2.13
string CSignalLogger::ReversionClassLabel(ENUM_REVERSION_CLASS c)
  {
   switch(c)
     {
      case REVERSION_VALUE_FADE:      return "ValueFade";
      case REVERSION_LEVEL_REJECTION: return "LevelRejection";
      case REVERSION_TREND_CONFLICT:  return "TrendConflict";
      default:                        return "None";
     }
  }
//+------------------------------------------------------------------+
// v2.14
string CSignalLogger::KeyLevelSourceLabel(ENUM_KEYLEVEL_SOURCE s)
  {
   switch(s)
     {
      case LEVEL_SR:              return "SR";
      case LEVEL_ORDER_BLOCK:      return "OrderBlock";
      case LEVEL_VALUE_AREA:       return "ValueArea";
      case LEVEL_LIQUIDITY_POOL:   return "LiquidityPool";
      default:                     return "None";
     }
  }
//+------------------------------------------------------------------+
// v2.14
string CSignalLogger::KeyLevelReactionLabel(ENUM_KEYLEVEL_REACTION r)
  {
   switch(r)
     {
      case REACTION_REJECTION:     return "Rejection";
      case REACTION_BREAK:         return "Break";
      case REACTION_RETEST:        return "Retest";
      case REACTION_FAILED_BREAK:  return "FailedBreak";
      case REACTION_ACCEPTANCE:    return "Acceptance";
      case REACTION_ABSORPTION:    return "Absorption";
      default:                     return "None";
     }
  }
//+------------------------------------------------------------------+
// v2.15
string CSignalLogger::SelectedStrategyLabel(ENUM_SELECTED_STRATEGY s)
  {
   switch(s)
     {
      case STRATEGY_SMC:                return "SMC";
      case STRATEGY_MOMENTUM_BREAKOUT:   return "MomentumBreakout";
      case STRATEGY_MEAN_REVERSION:      return "MeanReversion";
      case STRATEGY_KEY_LEVEL:           return "KeyLevel";
      default:                           return "None";
     }
  }
//+------------------------------------------------------------------+
string CSignalLogger::VAZoneLabel(ENUM_VALUE_AREA_ZONE z)
  {
   switch(z)
     {
      case VA_ZONE_BELOW:  return "Below";
      case VA_ZONE_INSIDE: return "Inside";
      case VA_ZONE_ABOVE:  return "Above";
      default:             return "Undefined";
     }
  }
//+------------------------------------------------------------------+
string CSignalLogger::FibZoneLabel(ENUM_FIB_ZONE z)
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
string CSignalLogger::FillPolicyLabel(ENUM_FILL_POLICY fp)
  {
   string s = EnumToString(fp);
   StringReplace(s, "FILL_", "");
   return s;
  }
//+------------------------------------------------------------------+
bool CSignalLogger::LogSetup(TradeSetup &setup, string symbol, ENUM_TIMEFRAMES entryTF, string trendLabel)
  {
   if(!setup.active) return false;

   int flags = FILE_CSV | FILE_READ | FILE_WRITE | FILE_SHARE_READ | FILE_ANSI;
   int handle = FileOpen(m_filename, flags, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("MedisTouch SignalLogger: failed to open ", m_filename, " err=", GetLastError());
      return false;
     }

   if(!m_headerWritten)
     {
      FileWrite(handle, "SignalID", "Symbol", "EntryTF", "DateTime", "Session", "Trend", "Direction",
               "Confidence", "EntryTop", "EntryBottom", "StopLoss", "TP1", "TP2", "FinalTP",
               "Reasons", "RiskWarning", "RVOL", "VolumeConfirmed", "FibZone", "FibInZone", "FibNearestLevel",
               "VAZone", "ValueAreaOK", "POC", "VAH", "VAL",
               "HtfOBConfluence", "HtfOBState", "VolRegime", "SessionOK",
               // v2.10 diagnostics. Appended, never inserted: parsers keyed
               // on column position keep working.
               "ContradictionPenalty", "EnvScore", "ExecScore", "EnvExecConfidence",
               // v2.12 diagnostics — same append-only discipline.
               "Regime", "MomentumScore", "BreakoutScore", "BreakoutClass",
               // v2.13 diagnostics — same append-only discipline.
               "ReversionScore", "ReversionClass",
               // v2.14 diagnostics — same append-only discipline.
               "KeyLevelSource", "KeyLevelReaction", "KeyLevelScore",
               // v2.15 diagnostics — same append-only discipline.
               "SelectedStrategy", "SelectedStrategyScore");
      m_headerWritten = true;
     }

   FileSeek(handle, 0, SEEK_END);
   string session = SessionLabel(setup.creation_time);
   string dir = (setup.type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   string risk = (StringLen(setup.reasons.risk_warning) > 0) ? setup.reasons.risk_warning : "None";
   // SignalID joins this row to its eventual outcome row in the Outcomes
   // CSV — just the creation timestamp + direction, unique enough for a
   // single-symbol, single-instance signal stream.
   string signalId = StringFormat("%s_%s_%d", symbol, dir, (long)setup.creation_time);

   FileWrite(handle, signalId, symbol, EnumToString(entryTF), TimeToString(setup.creation_time, TIME_DATE | TIME_MINUTES),
            session, trendLabel, dir, DoubleToString(setup.confidence, 1),
            DoubleToString(setup.entry_top, _Digits), DoubleToString(setup.entry_bottom, _Digits),
            DoubleToString(setup.stop_loss, _Digits), DoubleToString(setup.tp1, _Digits),
            DoubleToString(setup.tp2, _Digits), DoubleToString(setup.final_tp, _Digits),
            ReasonString(setup.reasons), risk,
            DoubleToString(setup.reasons.rvol, 2), setup.reasons.volume_confirmed ? "Yes" : "No",
            FibZoneLabel(setup.reasons.fib_zone), setup.reasons.fib_in_zone ? "Yes" : "No",
            DoubleToString(setup.reasons.fib_nearest_level, _Digits),
            VAZoneLabel(setup.reasons.va_zone), setup.reasons.value_area_ok ? "Yes" : "No",
            DoubleToString(setup.reasons.va_poc, _Digits), DoubleToString(setup.reasons.va_high, _Digits),
            DoubleToString(setup.reasons.va_low, _Digits),
            setup.reasons.htf_ob_confluence ? "Yes" : "No", OBStateLabel(setup.reasons.htf_ob_state),
            VolRegimeLabel(setup.reasons.vol_regime), setup.reasons.session_ok ? "Yes" : "No",
            DoubleToString(setup.reasons.contradiction_penalty, 3),
            DoubleToString(setup.reasons.env_score, 3),
            DoubleToString(setup.reasons.exec_score, 3),
            DoubleToString(setup.reasons.env_exec_confidence, 1),
            RegimeLabel(setup.reasons.regime),
            DoubleToString(setup.reasons.momentum_score, 1),
            DoubleToString(setup.reasons.breakout_score, 1),
            BreakoutClassLabel(setup.reasons.breakout_class),
            DoubleToString(setup.reasons.reversion_score, 1),
            ReversionClassLabel(setup.reasons.reversion_class),
            KeyLevelSourceLabel(setup.reasons.keylevel_source),
            KeyLevelReactionLabel(setup.reasons.keylevel_reaction),
            DoubleToString(setup.reasons.keylevel_score, 1),
            SelectedStrategyLabel(setup.reasons.selected_strategy),
            DoubleToString(setup.reasons.selected_strategy_score, 1));

   FileClose(handle);
   return true;
  }
//+------------------------------------------------------------------+
bool CSignalLogger::LogOutcome(PendingSetup &p, string symbol, ENUM_TIMEFRAMES entryTF, string outcome,
                               double exitPrice, ENUM_FILL_POLICY fillPolicy)
  {
   int flags = FILE_CSV | FILE_READ | FILE_WRITE | FILE_SHARE_READ | FILE_ANSI;
   int handle = FileOpen(m_outcomeFilename, flags, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("MedisTouch SignalLogger: failed to open ", m_outcomeFilename, " err=", GetLastError());
      return false;
     }

   if(!m_outcomeHeaderWritten)
     {
      FileWrite(handle, "SignalID", "Symbol", "EntryTF", "Direction", "Outcome", "ExitPrice",
               "EntryRef", "RiskDistance", "Filled", "FillTime", "BarsToFill", "MFE_Price", "MAE_Price",
               "MFE_R", "MAE_R", "TP1_Hit", "TP2_Hit", "BarsHeld", "SameBarSLTPCollision", "FillPolicy",
               "Lots", "EntryFillPrice", "BreakEvenDone", "PartialDone", "RealizedNetPnL", "RealizedR",
               "Commission", "SpreadCost", "SlippageCost",
               // v2.10 - the decay diagnostic, paired with the resolved
               // outcome so the retraining pipeline can test whether
               // staleness actually predicts a worse result.
               "ConfidenceAtSignal", "ConfidenceDecayed", "DecayBars",
               // Repeated from the signal row so an outcomes file is
               // self-sufficient for fitting the multiplicative model.
               "ContradictionPenalty", "EnvScore", "ExecScore", "EnvExecConfidence",
               // v2.12 — same "repeated from the signal row" rationale.
               "Regime", "MomentumScore", "BreakoutScore", "BreakoutClass",
               // v2.13 — same rationale.
               "ReversionScore", "ReversionClass",
               // v2.14 — same rationale.
               "KeyLevelSource", "KeyLevelReaction", "KeyLevelScore",
               // v2.15 — same rationale.
               "SelectedStrategy", "SelectedStrategyScore");
      m_outcomeHeaderWritten = true;
     }

   FileSeek(handle, 0, SEEK_END);
   string dir = (p.setup.type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   string signalId = StringFormat("%s_%s_%d", symbol, dir, (long)p.setup.creation_time);

   double mfeR = 0.0, maeR = 0.0;
   if(p.filled && p.riskDist > 0)
     {
      double mfeDist = (p.setup.type == ORDER_TYPE_BUY) ? (p.mfePrice - p.entryRef) : (p.entryRef - p.mfePrice);
      double maeDist = (p.setup.type == ORDER_TYPE_BUY) ? (p.entryRef - p.maePrice) : (p.maePrice - p.entryRef);
      mfeR = mfeDist / p.riskDist;
      maeR = maeDist / p.riskDist;
     }

   // Realized R uses mgmtRiskDist (the same basis the simulator's
   // breakeven/partial triggers are computed against) converted to a
   // dollar risk-per-1R for this trade's actual lot size — 0 if the
   // trade was never sized (lots<=0, e.g. risk% below broker minimum).
   double realizedR = 0.0;
   if(p.lots > 0 && p.mgmtRiskDist > 0)
     {
      double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize > 0 && tickValue > 0)
        {
         double oneRDollar = p.mgmtRiskDist * (tickValue / tickSize) * p.lots;
         if(oneRDollar > 0) realizedR = p.realizedPnL / oneRDollar;
        }
     }

   FileWrite(handle, signalId, symbol, EnumToString(entryTF), dir, outcome,
            DoubleToString(exitPrice, _Digits), DoubleToString(p.entryRef, _Digits),
            DoubleToString(p.riskDist, _Digits), p.filled ? "Yes" : "No",
            p.filled ? TimeToString(p.fillTime, TIME_DATE | TIME_MINUTES) : "",
            p.filled ? p.barsToFill : 0,
            DoubleToString(p.mfePrice, _Digits), DoubleToString(p.maePrice, _Digits),
            DoubleToString(mfeR, 2), DoubleToString(maeR, 2),
            p.tp1Hit ? "Yes" : "No", p.tp2Hit ? "Yes" : "No", p.barsElapsed,
            p.sameBarCollision ? "Yes" : "No", FillPolicyLabel(fillPolicy),
            DoubleToString(p.lots, 2), DoubleToString(p.entryFillPrice, _Digits),
            p.beDone ? "Yes" : "No", p.partialDone ? "Yes" : "No",
            DoubleToString(p.realizedPnL, 2), DoubleToString(realizedR, 2),
            DoubleToString(p.totalCommission, 2), DoubleToString(p.totalSpreadCost, 2),
            DoubleToString(p.totalSlippageCost, 2),
            DoubleToString(p.confidenceAtSignal, 1), DoubleToString(p.confidenceDecayed, 1),
            p.decayBars,
            DoubleToString(p.setup.reasons.contradiction_penalty, 3),
            DoubleToString(p.setup.reasons.env_score, 3),
            DoubleToString(p.setup.reasons.exec_score, 3),
            DoubleToString(p.setup.reasons.env_exec_confidence, 1),
            RegimeLabel(p.setup.reasons.regime),
            DoubleToString(p.setup.reasons.momentum_score, 1),
            DoubleToString(p.setup.reasons.breakout_score, 1),
            BreakoutClassLabel(p.setup.reasons.breakout_class),
            DoubleToString(p.setup.reasons.reversion_score, 1),
            ReversionClassLabel(p.setup.reasons.reversion_class),
            KeyLevelSourceLabel(p.setup.reasons.keylevel_source),
            KeyLevelReactionLabel(p.setup.reasons.keylevel_reaction),
            DoubleToString(p.setup.reasons.keylevel_score, 1),
            SelectedStrategyLabel(p.setup.reasons.selected_strategy),
            DoubleToString(p.setup.reasons.selected_strategy_score, 1));

   FileClose(handle);
   return true;
  }
#endif
//+------------------------------------------------------------------+
