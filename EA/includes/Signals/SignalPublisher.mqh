//+------------------------------------------------------------------+
//|                                     Signals/SignalPublisher.mqh   |
//+------------------------------------------------------------------+
#ifndef SIGNALPUBLISHER_MQH
#define SIGNALPUBLISHER_MQH

#include "../Decision/TradeDecision.mqh"
#include "SubscriberPlatform.mqh"
#include "../Core/PipCalculator.mqh"

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
   string               m_apiKey;    // sent as X-API-Key on every POST — must match telegram-bridge's SECRET_KEY

   bool                 TransmitOne(string endpoint, const string &payload);
   bool                 TransmitOnePatch(string endpoint, const string &payload);
   string               BuildJsonPayload(const TradeDecisionRecord &dec);
   string               BuildReasonsJsonArray(const SetupReasons &r);
   string               BuildExtraJson(const TradeDecisionRecord &dec);
   string               SignalIdFor(long decisionId);

public:
   void                 Init(string symbol, CSubscriberPlatform* platform, int timeoutMs = 5000, string apiKey = "");
   void                 Deinit();
   bool                 Publish(const TradeDecisionRecord &dec);
   // v2.9. Pushes a STALE/EXPIRED/INVALIDATED transition for a
   // previously-published decision. Fans out to the same subscriber
   // endpoints Publish() used, PATCHing "<endpoint-with-/signal-stripped>
   // /signal/<signal_id>/status" — this assumes each subscriber endpoint
   // ends in "/signal" (true for the current bridge deployment); if a
   // subscriber's endpoint doesn't follow that convention the PATCH for
   // that one subscriber is skipped (logged), not silently malformed.
   bool                 PublishStatusUpdate(long decisionId, string status, string reason);
  };
//+------------------------------------------------------------------+
void CSignalPublisher::Init(string symbol, CSubscriberPlatform* platform, int timeoutMs, string apiKey)
  {
   m_lastPublishedId = 0;
   m_platform = platform;
   m_timeoutMs = timeoutMs;
   m_apiKey = apiKey;
   if(StringLen(m_apiKey) == 0)
      Print("MedisTouch SignalPublisher: InpBridgeApiKey is blank — every WebRequest to the bridge will be ",
            "rejected with HTTP 401 until it's set to match the backend's SECRET_KEY.");
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
string CSignalPublisher::SignalIdFor(long decisionId)
  {
   // Matches the order-comment convention documented on
   // TradeDecisionRecord.decision_id ("MT#<id>") so a fill's comment and
   // its originating signal_id are trivially correlatable by eye.
   return "MT#" + IntegerToString(decisionId);
  }
//+------------------------------------------------------------------+
// v2.9. The bridge's SignalRequest schema requires signal_id (string),
// reasons (list[str], min 1 item), and timeframe — none of which the
// old payload sent. That's not a v2.9 regression; BuildJsonPayload
// never matched the schema it was posting against. Every field below is
// either newly added to close that gap (signal_id/reasons/timeframe) or
// was already correct and is unchanged (entry/sl/tp1/tp2/confidence).
string CSignalPublisher::BuildReasonsJsonArray(const SetupReasons &r)
  {
   string items[];
   int n = 0;
   #define MT_ADD_REASON(cond, txt) if(cond) { ArrayResize(items, n + 1); items[n++] = txt; }
   MT_ADD_REASON(r.trend_aligned,        "HTF trend aligned")
   MT_ADD_REASON(r.inducement_valid,     "Inducement sequence confirmed")
   MT_ADD_REASON(r.liquidity_swept,      "Liquidity swept")
   MT_ADD_REASON(r.bos_confirmed,        "BOS confirmed")
   MT_ADD_REASON(r.fresh_fvg,            "Fresh FVG in zone")
   MT_ADD_REASON(r.sr_confluence,        "S/R confluence")
   MT_ADD_REASON(r.premium_discount_ok,  "Premium/discount location OK")
   MT_ADD_REASON(r.volume_confirmed,     "Volume confirmed")
   MT_ADD_REASON(r.fib_in_zone,          "Fibonacci zone confluence")
   MT_ADD_REASON(r.value_area_ok,        "Value area location OK")
   MT_ADD_REASON(r.htf_ob_confluence,    "HTF order block confluence")
   #undef MT_ADD_REASON
   if(n == 0) { ArrayResize(items, 1); items[0] = "Confluence-based setup"; n = 1; } // schema requires min_length=1

   string json = "[";
   for(int i = 0; i < n; i++)
     {
      string esc = items[i];
      StringReplace(esc, "\"", "'");
      json += "\"" + esc + "\"";
      if(i < n - 1) json += ",";
     }
   json += "]";
   return json;
  }
//+------------------------------------------------------------------+
// v2.9. Everything from the review that's display-only diagnostic data,
// not required by the bridge schema — see routes.py:SignalRequest.extra
// and formatter.py's graceful-degradation handling if any key here is
// absent or this whole object is omitted.
string CSignalPublisher::BuildExtraJson(const TradeDecisionRecord &dec)
  {
   SetupReasons r = dec.setup.reasons;
   string symbol = dec.symbol;
   double pip = CPipCalculator::PipSize(symbol);
   bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
   double entry = isBuy ? dec.setup.entry_top : dec.setup.entry_bottom;

   double pipsSl  = (pip > 0) ? MathAbs(entry - dec.setup.stop_loss) / pip : 0.0;
   double pipsTp1 = (pip > 0) ? MathAbs(dec.setup.tp1 - entry) / pip : 0.0;
   double pipsTp2 = (pip > 0) ? MathAbs(dec.setup.tp2 - entry) / pip : 0.0;
   double rrTp1 = (pipsSl > 0) ? pipsTp1 / pipsSl : 0.0;
   double rrTp2 = (pipsSl > 0) ? pipsTp2 / pipsSl : 0.0;

   string sweepGradeStr = EnumToString(r.sweep_grade);
   string newsRiskStr = EnumToString(r.news_risk);

   return StringFormat(
      "{\"pips_sl\":%.1f,\"pips_tp1\":%.1f,\"pips_tp2\":%.1f,\"rr_tp1\":%.2f,\"rr_tp2\":%.2f,"
      "\"sweep_grade\":\"%s\",\"bos_strength\":%.1f,\"time_decay\":%.1f,"
      "\"chase_dist_atr\":%.2f,\"chase_ok\":%s,"
      "\"news_risk\":\"%s\",\"news_label\":\"%s\",\"news_minutes_to_event\":%d,"
      "\"calibrated_probability\":%.1f,\"calibration_sample\":%d,\"calibration_has_enough_data\":%s}",
      pipsSl, pipsTp1, pipsTp2, rrTp1, rrTp2,
      sweepGradeStr, r.bos_strength * 100.0, r.time_decay * 100.0,
      r.chase_dist_atr, r.chase_ok ? "true" : "false",
      newsRiskStr, r.news_label, r.news_minutes_to_event,
      dec.setup.calibrated_probability, dec.setup.calibration_sample,
      dec.setup.calibration_has_enough_data ? "true" : "false");
  }
//+------------------------------------------------------------------+
string CSignalPublisher::BuildJsonPayload(const TradeDecisionRecord &dec)
  {
   bool isBuy = (dec.setup.type == ORDER_TYPE_BUY);
   double entry = isBuy ? dec.setup.entry_top : dec.setup.entry_bottom;
   string dir = isBuy ? "BUY" : "SELL";
   string tf = EnumToString((ENUM_TIMEFRAMES)Period());
   StringReplace(tf, "PERIOD_", ""); // EnumToString gives "PERIOD_M15"; schema's VALID_TIMEFRAMES wants "M15"

   return StringFormat(
      "{\"signal_id\":\"%s\",\"decision_id\":%d,\"symbol\":\"%s\",\"direction\":\"%s\",\"entry\":%.5f,\"sl\":%.5f,"
      "\"tp1\":%.5f,\"tp2\":%.5f,\"final_tp\":%.5f,\"confidence\":%.1f,\"reasons\":%s,\"timeframe\":\"%s\","
      "\"time\":\"%s\",\"extra\":%s}",
      SignalIdFor(dec.decision_id), dec.decision_id, dec.symbol, dir, entry, dec.setup.stop_loss,
      dec.setup.tp1, dec.setup.tp2, dec.setup.final_tp, dec.setup.confidence,
      BuildReasonsJsonArray(dec.setup.reasons), tf,
      TimeToString(dec.decided_time, TIME_DATE | TIME_SECONDS), BuildExtraJson(dec));
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
   // X-API-Key is mandatory server-side (verify_api_key in routes.py has
   // no default) - every POST without it gets a 401 before the payload
   // is even validated. Concatenated as its own CRLF-terminated header
   // line per HTTP semantics; WebRequest() takes the whole header block
   // as one string.
   string headers = "Content-Type: application/json\r\n";
   if(StringLen(m_apiKey) > 0)
      headers += "X-API-Key: " + m_apiKey + "\r\n";

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
// v2.9. Same body as TransmitOne except the HTTP verb — WebRequest()
// takes the method as its first string argument, so this is the
// smallest correct duplication rather than a boolean flag threaded
// through the existing method (which already has enough parameters).
bool CSignalPublisher::TransmitOnePatch(string endpoint, const string &payload)
  {
   uchar rawData[];
   int len = StringToCharArray(payload, rawData) - 1;
   if(len < 0) len = 0;
   ArrayResize(rawData, len);

   char data[];
   ArrayResize(data, len);
   ArrayCopy(data, rawData);

   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\n";
   if(StringLen(m_apiKey) > 0)
      headers += "X-API-Key: " + m_apiKey + "\r\n";

   ResetLastError();
   int status = WebRequest("PATCH", endpoint, headers, m_timeoutMs, data, result, resultHeaders);
   if(status == -1)
     {
      PrintFormat("MedisTouch SignalPublisher: lifecycle PATCH to %s failed, error %d.", endpoint, GetLastError());
      return false;
     }
   if(status < 200 || status >= 300)
     {
      PrintFormat("MedisTouch SignalPublisher: lifecycle PATCH %s responded with HTTP %d.", endpoint, status);
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
//+------------------------------------------------------------------+
bool CSignalPublisher::PublishStatusUpdate(long decisionId, string status, string reason)
  {
   if(m_platform == NULL) return false;
   string signalId = SignalIdFor(decisionId);
   string escReason = reason;
   StringReplace(escReason, "\"", "'");
   string payload = StringFormat("{\"status\":\"%s\",\"reason\":\"%s\"}", status, escReason);

   Subscriber subs[];
   int targeted = m_platform.GetActiveSubscribers(subs);
   bool anyOk = false;
   for(int i = 0; i < targeted; i++)
     {
      string endpoint = subs[i].endpoint;
      int pos = StringFind(endpoint, "/signal");
      if(pos < 0)
        {
         PrintFormat("MedisTouch SignalPublisher: subscriber endpoint %s doesn't end in /signal — skipping lifecycle PATCH for it.", endpoint);
         continue;
        }
      string patchUrl = StringSubstr(endpoint, 0, pos) + "/signal/" + signalId + "/status";
      if(TransmitOnePatch(patchUrl, payload)) anyOk = true;
     }
   return anyOk;
  }
#endif
//+------------------------------------------------------------------+
