//+------------------------------------------------------------------+
//|                                      Decision/DecisionEngine.mqh |
//|  The analysis -> action router: turns a validated TradeSetup into  |
//|  an explicit, ID'd, auditable TradeDecisionRecord.                |
//+------------------------------------------------------------------+
// Why this exists as its own layer instead of the EA calling
// COrderManager directly: "should we act on this setup at all, and how"
// is policy, not execution. Keeping it here means execution, signalling
// and persistence all receive the SAME immutable record, so the order
// that gets placed, the message subscribers receive, and the row Recovery
// later reads can never disagree about entry/SL/TP/confidence.
#ifndef DECISIONENGINE_MQH
#define DECISIONENGINE_MQH

#include "../Core/Config.mqh"
#include "TradeDecision.mqh"

class CDecisionEngine
  {
private:
   string            m_symbol;
   bool              m_enableExecution;
   bool              m_enableSignals;
   double            m_minConfidenceExecute;
   double            m_minConfidenceSignal;
   double            m_fullRiskConfidence;
   int               m_maxSpreadPoints;      // 0 = no spread gate
   long              m_nextId;

   double            CurrentSpreadPoints() const;

public:
                     CDecisionEngine();
   void              Init(const string symbol, bool enableExecution, bool enableSignals,
                          double minConfidenceExecute, double minConfidenceSignal,
                          double fullRiskConfidence, int maxSpreadPoints);
   // Recovery/restart safety: decision IDs are the matching key baked into
   // broker order comments, so a fresh instance must never reissue one.
   void              SeedNextId(long nextId);
   long              PeekNextId() const { return m_nextId; }
   TradeDecisionRecord Decide(const TradeSetup &setup);
  };
//+------------------------------------------------------------------+
CDecisionEngine::CDecisionEngine() : m_symbol(""), m_enableExecution(false), m_enableSignals(false),
                                     m_minConfidenceExecute(0.0), m_minConfidenceSignal(0.0),
                                     m_fullRiskConfidence(0.0), m_maxSpreadPoints(0), m_nextId(1) {}
//+------------------------------------------------------------------+
void CDecisionEngine::Init(const string symbol, bool enableExecution, bool enableSignals,
                           double minConfidenceExecute, double minConfidenceSignal,
                           double fullRiskConfidence, int maxSpreadPoints)
  {
   m_symbol = (symbol == "") ? _Symbol : symbol;
   m_enableExecution = enableExecution;
   m_enableSignals = enableSignals;
   m_minConfidenceExecute = minConfidenceExecute;
   m_minConfidenceSignal = minConfidenceSignal;
   m_fullRiskConfidence = fullRiskConfidence;
   m_maxSpreadPoints = MathMax(0, maxSpreadPoints);
  }
//+------------------------------------------------------------------+
void CDecisionEngine::SeedNextId(long nextId)
  {
   if(nextId > m_nextId) m_nextId = nextId;
  }
//+------------------------------------------------------------------+
double CDecisionEngine::CurrentSpreadPoints() const
  {
   // SYMBOL_SPREAD is already in points. It can legitimately be 0 on a
   // symbol the broker quotes with a floating spread while the market is
   // closed - fall back to the raw ask/bid difference in that case so the
   // gate isn't silently bypassed at weekend/rollover.
   long spread = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
   if(spread > 0) return (double)spread;

   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   if(point <= 0) return 0.0;
   double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return 0.0;
   return (ask - bid) / point;
  }
//+------------------------------------------------------------------+
// Returns a record with valid=false / POLICY_IGNORE for anything that
// should not be acted on. It never throws away the reason - the caller
// (and the CSV store) keeps it, because "why did the EA not take that
// setup" is the single most common question in production.
TradeDecisionRecord CDecisionEngine::Decide(const TradeSetup &setup)
  {
   TradeDecisionRecord rec;
   ZeroMemory(rec);
   rec.symbol = m_symbol;
   rec.setup = setup;
   rec.confidence = setup.confidence;
   rec.decided_time = TimeCurrent();
   rec.action = POLICY_IGNORE;
   rec.valid = false;
   rec.spread_points = CurrentSpreadPoints();

   if(!setup.active)
     {
      rec.reason = "setup inactive";
      return rec;
     }
   if(!m_enableExecution && !m_enableSignals)
     {
      rec.reason = "execution and signals both disabled";
      return rec;
     }

   bool canExecute = m_enableExecution && setup.confidence >= m_minConfidenceExecute;
   bool canSignal  = m_enableSignals  && setup.confidence >= m_minConfidenceSignal;

   // Spread gate applies to EXECUTION only. A wide spread makes the fill
   // bad; it does not make the analysis wrong, so subscribers still get
   // the signal (they may be on a different broker entirely).
   if(canExecute && m_maxSpreadPoints > 0 && rec.spread_points > (double)m_maxSpreadPoints)
     {
      canExecute = false;
      rec.reason = StringFormat("execution skipped: spread %.0f pts > max %d pts; ",
                                rec.spread_points, m_maxSpreadPoints);
     }

   if(canExecute && canSignal)      rec.action = POLICY_EXECUTE_AND_SIGNAL;
   else if(canExecute)              rec.action = POLICY_EXECUTE_ONLY;
   else if(canSignal)               rec.action = POLICY_SIGNAL_ONLY;

   if(rec.action == POLICY_IGNORE)
     {
      rec.reason += StringFormat("confidence %.1f below thresholds (execute %.1f / signal %.1f)",
                                 setup.confidence, m_minConfidenceExecute, m_minConfidenceSignal);
      return rec;
     }

   // Below the "full risk" confidence the setup is still tradable, just
   // not at full size - CRiskEngine::CalculateLotSize() halves it when
   // reduce_risk is set.
   rec.reduce_risk = (setup.confidence < m_fullRiskConfidence);
   rec.valid = true;
   rec.decision_id = m_nextId++;
   rec.reason += StringFormat("%s at confidence %.1f%s", TradePolicyToString(rec.action),
                              setup.confidence, rec.reduce_risk ? " (reduced risk)" : "");
   return rec;
  }
#endif
//+------------------------------------------------------------------+
