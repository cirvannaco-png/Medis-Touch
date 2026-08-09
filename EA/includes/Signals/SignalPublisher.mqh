//+------------------------------------------------------------------+
//|                                     Signals/SignalPublisher.mqh   |
//+------------------------------------------------------------------+
#ifndef SIGNALPUBLISHER_MQH
#define SIGNALPUBLISHER_MQH

#include "../Decision/TradeDecision.mqh"
#include "SubscriberPlatform.mqh"

// Publish/format/dedup/transport side of the Signal Distribution Engine.
//
// TRANSPORT IS NOW REAL: TransmitOne() calls WebRequest() against each
// active subscriber's endpoint from CSubscriberPlatform. Two things this
// genuinely cannot do for you, both one-time manual setup outside this
// file, not a code gap:
//   1. Every domain you publish to must be added under Tools > Options >
//      Expert Advisors > "Allow WebRequest for listed URL" in the
//      running terminal. WebRequest() fails immediately (returns -1,
//      GetLastError() 4060) against anything not on that list — an MT5
//      platform restriction, not something an EA can configure around
//      from inside itself.
//   2. Endpoints are whatever "MedisTouch_Subscribers.csv" defines via
//      CSubscriberPlatform — populate it with real subscriber endpoints
//      before anything gets delivered. An empty file means Publish()
//      still runs and still logs to the local feed, it just has nobody
//      to send to.
class CSignalPublisher
  {
private:
   string               m_filename;
   int                  m_fileHandle;
   long                 m_lastPublishedId;
   CSubscriberPlatform* m_platform;
   int                  m_timeoutMs;

   bool                 TransmitOne(string endpoint, const string &payload);
   string               BuildJsonPayload(const TradeDecisionRecord &dec);

public:
   void                 Init(string symbol, CSubscriberPlatform* platform, int timeoutMs = 5000);
   void                 Deinit();
   bool                 Publish(const TradeDecisionRecord &dec);
  };
//+------------------------------------------------------------------+
void CSignalPublisher::Init(string symbol, CSubscriberPlatform* platform, int timeoutMs)
  {
   m_lastPublishedId = 0;
   m_platform = platform;
   m_timeoutMs = timeoutMs;
   m_filename = "MedisTouch_SignalFeed_" + symbol + ".csv";
   bool exists = FileIsExist(m_filename);
   m_fileHandle = FileOpen(m_filename, FILE_READ | FILE_WRITE | FILE_CSV, ',');
   if(m_fileHandle == INVALID_HANDLE)
     {
      Print("MedisTouch SignalPublisher: could not open ", m_filename);
      return;
     }
   FileSeek(m_fileHandle, 0, SEEK_END);
   if(!exists)
      FileWrite(m_fileHandle, "DecisionID", "Time", "Symbol", "Direction", "Entry", "SL", "TP1", "TP2", "FinalTP",
                "Confidence", "Action", "SubscribersTargeted", "SubscribersDelivered");
  }
//+------------------------------------------------------------------+
void CSignalPublisher::Deinit()
  {
   if(m_fileHandle != INVALID_HANDLE) FileClose(m_fileHandle);
  }
//+------------------------------------------------------------------+
string CSignalPublisher::BuildJsonPayload(const TradeDecisionRecord &dec)
  {
   bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
   double entry = isBuy ? dec.setup.entry_top : dec.setup.entry_bottom;
   string dir = isBuy ? "BUY" : "SELL";

   return StringFormat(
      "{\"decision_id\":%d,\"symbol\":\"%s\",\"direction\":\"%s\",\"entry\":%.5f,\"sl\":%.5f,"
      "\"tp1\":%.5f,\"tp2\":%.5f,\"final_tp\":%.5f,\"confidence\":%.1f,\"time\":\"%s\"}",
      dec.decision_id, dec.symbol, dir, entry, dec.setup.stop_loss,
      dec.setup.tp1, dec.setup.tp2, dec.setup.final_tp, dec.setup.confidence,
      TimeToString(dec.decided_time, TIME_DATE | TIME_SECONDS));
  }
//+------------------------------------------------------------------+
bool CSignalPublisher::TransmitOne(string endpoint, const string &payload)
  {
   // StringToCharArray() fills a uchar[] array; WebRequest()'s data
   // parameter is declared char[] — these are distinct array types in
   // MQL5 and a reference parameter won't implicitly convert between
   // them, so building straight into a char[] and handing it to
   // StringToCharArray would fail to compile. Build into uchar[] first,
   // then ArrayCopy() into the char[] WebRequest actually wants —
   // ArrayCopy() performs the element-wise cast, a plain assignment
   // would not.
   uchar rawData[];
   int len = StringToCharArray(payload, rawData) - 1; // trim the trailing null StringToCharArray appends
   if(len < 0) len = 0;
   ArrayResize(rawData, len);

   char data[];
   ArrayResize(data, len);
   ArrayCopy(data, rawData);

   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\n";

   ResetLastError();
   int status = WebRequest("POST", endpoint, headers, m_timeoutMs, data, result, resultHeaders);
   if(status == -1)
     {
      int err = GetLastError();
      if(err == 4060)
         PrintFormat("MedisTouch SignalPublisher: WebRequest blocked for %s — add it under Tools > Options > Expert Advisors > Allow WebRequest for listed URL.",
                     endpoint);
      else
         PrintFormat("MedisTouch SignalPublisher: WebRequest to %s failed, error %d.", endpoint, err);
      return false;
     }
   if(status < 200 || status >= 300)
     {
      PrintFormat("MedisTouch SignalPublisher: %s responded with HTTP %d.", endpoint, status);
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
bool CSignalPublisher::Publish(const TradeDecisionRecord &dec)
  {
   if(dec.action != POLICY_SIGNAL_ONLY && dec.action != POLICY_EXECUTE_AND_SIGNAL) return false;
   if(dec.decision_id == m_lastPublishedId) return false; // dedup against re-publishing the same decision
   if(m_fileHandle == INVALID_HANDLE) return false;

   bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
   double entry = isBuy ? dec.setup.entry_top : dec.setup.entry_bottom;
   string dir = isBuy ? "BUY" : "SELL";
   string payload = BuildJsonPayload(dec);

   int targeted = 0;
   int delivered = 0;

   if(m_platform != NULL)
     {
      Subscriber subs[];
      targeted = m_platform.GetActiveSubscribers(subs);
      for(int i = 0; i < targeted; i++)
        {
         bool ok = TransmitOne(subs[i].endpoint, payload);
         if(ok) delivered++;
         m_platform.RecordDelivery(subs[i].id, dec.decision_id, ok);
        }
     }

   FileWrite(m_fileHandle, dec.decision_id, TimeToString(dec.decided_time, TIME_DATE | TIME_MINUTES), dec.symbol,
             dir, entry, dec.setup.stop_loss, dec.setup.tp1, dec.setup.tp2, dec.setup.final_tp,
             dec.setup.confidence, EnumToString(dec.action), targeted, delivered);
   FileFlush(m_fileHandle);

   m_lastPublishedId = dec.decision_id;
   return true;
  }
#endif
//+------------------------------------------------------------------+
