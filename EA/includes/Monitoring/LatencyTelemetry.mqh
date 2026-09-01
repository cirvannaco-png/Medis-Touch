//+------------------------------------------------------------------+
//|                                Monitoring/LatencyTelemetry.mqh    |
//| End-to-end detection -> decision -> risk -> broker -> fill timing |
//+------------------------------------------------------------------+
#ifndef LATENCYTELEMETRY_MQH
#define LATENCYTELEMETRY_MQH

class CLatencyTelemetry
  {
private:
   ulong   m_t0, m_t1, m_t2, m_t3, m_t4, m_t5, m_t6, m_t7;
   long    m_decisionId;
   string  m_symbol;
   bool    m_active;
   bool    m_waitingForFill;

   double Ms(ulong a, ulong b) const
     { return (a > 0 && b >= a) ? (double)(b - a) / 1000.0 : -1.0; }

   void WriteRow()
     {
      string filename = "MedisTouch_Latency_" + m_symbol + ".csv";
      int h = FileOpen(filename, FILE_READ|FILE_WRITE|FILE_CSV|FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_ANSI, ',');
      if(h == INVALID_HANDLE) return;
      if(FileSize(h) == 0)
        FileWrite(h, "server_time", "decision_id", "symbol",
                  "t0_market_observed_us", "t1_detection_us", "t2_confidence_us",
                  "t3_decision_us", "t4_risk_us", "t5_submission_us",
                  "t6_broker_ack_us", "t7_fill_observed_us",
                  "detection_ms", "decision_ms", "risk_ms", "submission_ms",
                  "broker_ms", "fill_ms", "total_signal_to_fill_ms");
      FileSeek(h, 0, SEEK_END);
      FileWrite(h,
                TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                m_decisionId, m_symbol,
                (string)m_t0, (string)m_t1, (string)m_t2, (string)m_t3,
                (string)m_t4, (string)m_t5, (string)m_t6, (string)m_t7,
                DoubleToString(Ms(m_t0, m_t1), 3),
                DoubleToString(Ms(m_t1, m_t3), 3),
                DoubleToString(Ms(m_t3, m_t4), 3),
                DoubleToString(Ms(m_t4, m_t5), 3),
                DoubleToString(Ms(m_t5, m_t6), 3),
                DoubleToString(Ms(m_t6, m_t7), 3),
                DoubleToString(Ms(m_t0, m_t7), 3));
      FileClose(h);
     }

   void Reset(string symbol)
     {
      m_symbol = symbol;
      m_decisionId = 0;
      m_t0 = GetMicrosecondCount();
      m_t1 = m_t2 = m_t3 = m_t4 = m_t5 = m_t6 = m_t7 = 0;
      m_waitingForFill = false;
      m_active = true;
     }

public:
   CLatencyTelemetry() : m_t0(0), m_t1(0), m_t2(0), m_t3(0), m_t4(0), m_t5(0), m_t6(0), m_t7(0),
                              m_decisionId(0), m_symbol(""), m_active(false), m_waitingForFill(false) {}

   void BeginIfInactive(string symbol)
     {
      if(!m_active) { Reset(symbol); return; }
      if(!m_waitingForFill && m_t1 > 0)
        {
         // Preserve partial traces (including ignored/risk-blocked setups)
         // before starting the next decision cycle.
         Finalize(false);
         Reset(symbol);
        }
     }

   void SetDecisionId(long id) { m_decisionId = id; }
   void MarkDetection() { if(m_active) m_t1 = GetMicrosecondCount(); }
   void MarkConfidence() { if(m_active) m_t2 = GetMicrosecondCount(); }
   void MarkDecision() { if(m_active) m_t3 = GetMicrosecondCount(); }
   void MarkRisk() { if(m_active) m_t4 = GetMicrosecondCount(); }
   void MarkSubmission() { if(m_active) m_t5 = GetMicrosecondCount(); }
   void MarkBrokerAck() { if(m_active) m_t6 = GetMicrosecondCount(); }
   void MarkFillObserved() { if(m_active) m_t7 = GetMicrosecondCount(); }
   bool Active() const { return m_active; }
   long DecisionId() const { return m_decisionId; }

   void Finalize(bool requireFill = false)
     {
      if(!m_active) return;
      if(requireFill && m_t7 == 0) return;
      WriteRow();
      m_active = false;
      m_waitingForFill = false;
     }

   void KeepPending() { if(m_active) m_waitingForFill = true; }
  };

CLatencyTelemetry g_latency;

#endif
//+------------------------------------------------------------------+
