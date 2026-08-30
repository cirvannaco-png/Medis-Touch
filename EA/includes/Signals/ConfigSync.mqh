//+------------------------------------------------------------------+
//| ConfigSync.mqh                                                    |
//|                                                                    |
//| v2.11. Polls the bridge's GET /config/{symbol} on a timer and      |
//| compares whatever weight_version it reports as "approved" against  |
//| this instance's compiled InpWeightSetVersion.                      |
//|                                                                    |
//| DELIBERATELY OBSERVATION-ONLY. This does NOT change confidence      |
//| thresholds, FVG proximity, or any other live parameter — there is  |
//| no numeric-parameter-proposal engine yet (see the bridge's         |
//| ConfigResponse.params, always null today), so there is nothing     |
//| correct to auto-apply. What this DOES do: close the loop on "did   |
//| the approval I tapped in Telegram actually reach every running EA  |
//| instance," which today is a manual recompile-and-redeploy step per |
//| chart with no feedback if you miss one.                            |
//|                                                                    |
//| DORMANT BY CONSTRUCTION: until a human approves a weight_version   |
//| via the Telegram tap-to-approve card (see app/bot_promotions.py),  |
//| GET /config/{symbol} returns approved_weight_version=null and this |
//| class does nothing but log a one-line heartbeat. The moment a real |
//| promotion happens, the exact same polling loop — no code change —  |
//| starts detecting drift. This mirrors the same "dummy data now,     |
//| real data activates it later" property tools/gating.py's           |
//| source-tagging gives the recalibration cycle, applied to config    |
//| sync instead of promotion decisions.                                |
//+------------------------------------------------------------------+
#ifndef CONFIGSYNC_MQH
#define CONFIGSYNC_MQH

class CConfigSync
  {
private:
   string   m_symbol;
   string   m_endpoint;      // "<bridge base>/config/<symbol>"
   string   m_apiKey;
   string   m_compiledWeightVersion;
   int      m_timeoutMs;
   string   m_lastSeenApproved; // "" until first successful poll; then whatever the bridge last reported (may be "")
   bool     m_everWarned;       // avoid re-logging the same drift every single poll — see Poll()

   bool     ExtractJsonStringField(const string &json, string field, string &out);

public:
            CConfigSync(void) : m_timeoutMs(5000), m_lastSeenApproved(""), m_everWarned(false) {}

   // signalEndpoint is the same base URL already configured for /signal
   // (a subscriber endpoint) — this derives /config/<symbol> from it by
   // the same "strip trailing /signal" convention SignalPublisher's
   // PublishStatusUpdate()/PublishOutcome() already use, so there is only
   // ONE place (SubscriberPlatform's endpoint config) that needs the
   // bridge's base URL, not a second copy of it for this class.
   void     Init(string symbol, string signalEndpoint, string apiKey, string compiledWeightVersion, int timeoutMs = 5000)
     {
      m_symbol = symbol;
      m_apiKey = apiKey;
      m_compiledWeightVersion = compiledWeightVersion;
      m_timeoutMs = timeoutMs;

      int pos = StringFind(signalEndpoint, "/signal");
      if(pos < 0)
        {
         PrintFormat("MedisTouch ConfigSync: endpoint %s doesn't end in /signal — config sync disabled for this instance.", signalEndpoint);
         m_endpoint = "";
         return;
        }
      m_endpoint = StringSubstr(signalEndpoint, 0, pos) + "/config/" + symbol;
     }

   // Call from OnTimer(). No-op if Init() couldn't derive a valid
   // endpoint. Every poll is a single GET; failures are logged once via
   // WebRequest's own error path and otherwise ignored — a transient
   // network blip here is not worth retry/backoff machinery, since the
   // next timer tick tries again anyway and nothing time-sensitive
   // depends on this succeeding on any particular tick.
   void     Poll(void);
  };

void CConfigSync::Poll(void)
  {
   if(StringLen(m_endpoint) == 0) return;

   char data[]; // GET has no body
   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\n";
   if(StringLen(m_apiKey) > 0)
      headers += "X-API-Key: " + m_apiKey + "\r\n";

   ResetLastError();
   int status = WebRequest("GET", m_endpoint, headers, m_timeoutMs, data, result, resultHeaders);
   if(status == -1)
     {
      int err = GetLastError();
      if(err == 4060)
         PrintFormat("MedisTouch ConfigSync: WebRequest blocked for %s — add it under Tools > Options > Expert Advisors > Allow WebRequest for listed URL.", m_endpoint);
      // Other errors: silent per-poll, per the class comment above — the
      // next timer tick retries on its own.
      return;
     }
   if(status < 200 || status >= 300) return;

   string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string approved;
   if(!ExtractJsonStringField(body, "approved_weight_version", approved))
      return; // malformed/unexpected response shape — nothing to act on

   m_lastSeenApproved = approved;

   if(StringLen(approved) == 0)
      return; // nothing ever approved yet — the expected, dormant state

   if(approved != m_compiledWeightVersion && !m_everWarned)
     {
      PrintFormat("MedisTouch ConfigSync: bridge reports '%s' as the latest approved weight_version, "
                  "but this %s instance is compiled with InpWeightSetVersion='%s'. Recompile/redeploy "
                  "this chart to match, or this instance keeps running its own weights — nothing is "
                  "applied automatically (see ConfigSync.mqh header).",
                  approved, m_symbol, m_compiledWeightVersion);
      m_everWarned = true; // one warning per drift episode, not one per poll — see Poll()'s own comment
     }
   else if(approved == m_compiledWeightVersion)
     {
      m_everWarned = false; // drift resolved (redeployed, or a new approval matched this instance) — rearm
     }
  }

// Deliberately NOT a general JSON parser — the bridge's ConfigResponse
// shape is fixed and small (see routes.py:ConfigResponse), so a targeted
// string search for `"field":"value"` or `"field":null` is enough and
// avoids pulling in a full parser for one endpoint. If this class ever
// needs to read more than a couple of top-level string fields, that's
// the signal to introduce a real JSON library instead of extending this.
bool CConfigSync::ExtractJsonStringField(const string &json, string field, string &out)
  {
   string needle = "\"" + field + "\":";
   int pos = StringFind(json, needle);
   if(pos < 0) return false;
   int valueStart = pos + StringLen(needle);

   if(StringSubstr(json, valueStart, 4) == "null")
     {
      out = "";
      return true;
     }
   if(StringGetCharacter(json, valueStart) != '"') return false; // unexpected shape
   valueStart++; // skip opening quote
   int valueEnd = StringFind(json, "\"", valueStart);
   if(valueEnd < 0) return false;
   out = StringSubstr(json, valueStart, valueEnd - valueStart);
   return true;
  }

#endif // CONFIGSYNC_MQH
