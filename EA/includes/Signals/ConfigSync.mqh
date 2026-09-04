//+------------------------------------------------------------------+
//| ConfigSync.mqh                                                    |
//| Production configuration validation + acknowledgement.            |
//|                                                                    |
//| The EA never mutates trading parameters from an HTTP response.     |
//| It validates the registry payload, acknowledges that validation,   |
//| and leaves activation to an explicit EA release.                   |
//+------------------------------------------------------------------+
#ifndef CONFIGSYNC_MQH
#define CONFIGSYNC_MQH

class CConfigSync
  {
private:
   string   m_symbol;
   string   m_endpoint;
   string   m_ackEndpoint;
   string   m_apiKey;
   string   m_compiledWeightVersion;
   int      m_timeoutMs;
   string   m_lastSeenHash;

   bool ExtractJsonStringField(const string &json, string field, string &out);
   bool ExtractJsonNumberField(const string &json, string field, double &out);
   bool ValidateParams(const string &json, string &reason);
   void Ack(const string &configHash, const string &status, const string &reason);

public:
   CConfigSync(void) : m_timeoutMs(5000), m_lastSeenHash("") {}

   void Init(string symbol, string signalEndpoint, string apiKey, string compiledWeightVersion, int timeoutMs = 5000)
     {
      m_symbol = symbol;
      m_apiKey = apiKey;
      m_compiledWeightVersion = compiledWeightVersion;
      m_timeoutMs = timeoutMs;

      int pos = StringFind(signalEndpoint, "/signal");
      if(pos < 0)
        {
         m_endpoint = "";
         m_ackEndpoint = "";
         PrintFormat("MedisTouch ConfigSync: endpoint %s doesn't contain /signal; sync disabled.", signalEndpoint);
         return;
        }
      string base = StringSubstr(signalEndpoint, 0, pos);
      m_endpoint = base + "/config/" + symbol;
      m_ackEndpoint = base + "/config/" + symbol + "/ack";
     }

   void Poll(void);
  };

void CConfigSync::Ack(const string &configHash, const string &status, const string &reason)
  {
   if(StringLen(m_ackEndpoint) == 0 || StringLen(configHash) != 64) return;

   string escapedReason = reason;
   StringReplace(escapedReason, "\\", "\\\\");
   StringReplace(escapedReason, "\"", "\\\"");
   string instance = IntegerToString((int)ChartID());
   string body = "{\"config_hash\":\"" + configHash + "\","
                 + "\"ea_instance\":\"" + instance + "\","
                 + "\"status\":\"" + status + "\","
                 + "\"ea_version\":\"" + m_compiledWeightVersion + "\","
                 + "\"reason\":\"" + escapedReason + "\"}";

   char data[];
   StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\n";
   if(StringLen(m_apiKey) > 0)
      headers += "X-API-Key: " + m_apiKey + "\r\n";

   ResetLastError();
   int statusCode = WebRequest("POST", m_ackEndpoint, headers, m_timeoutMs, data, result, resultHeaders);
   if(statusCode < 200 || statusCode >= 300)
      PrintFormat("MedisTouch ConfigSync: ACK failed for %s (HTTP %d, err %d).", configHash, statusCode, GetLastError());
  }

bool CConfigSync::ExtractJsonStringField(const string &json, string field, string &out)
  {
   string needle = "\"" + field + "\":";
   int pos = StringFind(json, needle);
   if(pos < 0) return false;
   int valueStart = pos + StringLen(needle);
   if(StringSubstr(json, valueStart, 4) == "null") { out = ""; return true; }
   if(StringGetCharacter(json, valueStart) != '"') return false;
   valueStart++;
   int valueEnd = StringFind(json, "\"", valueStart);
   if(valueEnd < 0) return false;
   out = StringSubstr(json, valueStart, valueEnd - valueStart);
   return true;
  }

bool CConfigSync::ExtractJsonNumberField(const string &json, string field, double &out)
  {
   string needle = "\"" + field + "\":";
   int pos = StringFind(json, needle);
   if(pos < 0) return false;
   int start = pos + StringLen(needle);
   int end = start;
   int length = StringLen(json);
   while(end < length)
     {
      ushort ch = StringGetCharacter(json, end);
      if((ch >= '0' && ch <= '9') || ch == '-' || ch == '+' || ch == '.' || ch == 'e' || ch == 'E')
        { end++; continue; }
      break;
     }
   if(end == start) return false;
   string token = StringSubstr(json, start, end - start);
   out = StringToDouble(token);
   return MathIsValidNumber(out);
  }

bool CConfigSync::ValidateParams(const string &json, string &reason)
  {
   int paramsPos = StringFind(json, "\"params\":{");
   if(paramsPos < 0) { reason = "params_missing"; return false; }
   string params = StringSubstr(json, paramsPos);

   double v;
   if(!ExtractJsonNumberField(params, "ensemble_threshold", v) || v < 55 || v > 85) { reason = "ensemble_threshold_out_of_bounds"; return false; }
   if(!ExtractJsonNumberField(params, "smc_threshold", v) || v < 50 || v > 85) { reason = "smc_threshold_out_of_bounds"; return false; }
   if(!ExtractJsonNumberField(params, "momentum_threshold", v) || v < 50 || v > 85) { reason = "momentum_threshold_out_of_bounds"; return false; }
   if(!ExtractJsonNumberField(params, "breakout_threshold", v) || v < 50 || v > 85) { reason = "breakout_threshold_out_of_bounds"; return false; }
   if(!ExtractJsonNumberField(params, "mean_reversion_threshold", v) || v < 50 || v > 85) { reason = "mean_reversion_threshold_out_of_bounds"; return false; }
   if(!ExtractJsonNumberField(params, "key_level_threshold", v) || v < 50 || v > 85) { reason = "key_level_threshold_out_of_bounds"; return false; }
   if(!ExtractJsonNumberField(params, "fvg_proximity_atr", v) || v < 0.05 || v > 1.00) { reason = "fvg_proximity_atr_out_of_bounds"; return false; }
   if(!ExtractJsonNumberField(params, "contradiction_penalty", v) || v < 0.0 || v > 0.50) { reason = "contradiction_penalty_out_of_bounds"; return false; }
   if(!ExtractJsonNumberField(params, "freshness_bars", v) || v < 3 || v > 30) { reason = "freshness_bars_out_of_bounds"; return false; }
   return true;
  }

void CConfigSync::Poll(void)
  {
   if(StringLen(m_endpoint) == 0) return;

   char data[];
   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\n";
   if(StringLen(m_apiKey) > 0)
      headers += "X-API-Key: " + m_apiKey + "\r\n";

   ResetLastError();
   int status = WebRequest("GET", m_endpoint, headers, m_timeoutMs, data, result, resultHeaders);
   if(status == -1) return;
   if(status < 200 || status >= 300) return;

   string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string configHash;
   if(!ExtractJsonStringField(body, "config_hash", configHash)) return;
   if(StringLen(configHash) == 0 || StringLen(configHash) != 64) return;
   if(configHash == m_lastSeenHash) return;

   string parentVersion;
   if(!ExtractJsonStringField(body, "parent_version", parentVersion)) return;
   if(parentVersion != m_compiledWeightVersion)
     {
      m_lastSeenHash = configHash;
      PrintFormat("MedisTouch ConfigSync: rejected config %s for %s — parent '%s' does not match compiled weight version '%s'.",
                  configHash, m_symbol, parentVersion, m_compiledWeightVersion);
      Ack(configHash, "REJECTED", "parent_version_mismatch");
      return;
     }

   string reason;
   if(!ValidateParams(body, reason))
     {
      m_lastSeenHash = configHash;
      PrintFormat("MedisTouch ConfigSync: rejected config %s for %s: %s", configHash, m_symbol, reason);
      Ack(configHash, "REJECTED", reason);
      return;
     }

   m_lastSeenHash = configHash;
   // Validation is deliberately separate from activation. This build does
   // not dynamically mutate compiled strategy parameters. VALIDATED means
   // only that the EA accepted the registry schema, hash and bounds.
   Ack(configHash, "VALIDATED", "schema_bounds_and_parent_valid; runtime_application_not_enabled");
  }

#endif // CONFIGSYNC_MQH
