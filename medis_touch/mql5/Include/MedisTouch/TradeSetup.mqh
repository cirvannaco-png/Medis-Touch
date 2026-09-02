//+------------------------------------------------------------------+
//| TradeSetup.mqh                                                    |
//| Canonical TradeSetup contract - handbook section 3, verbatim.     |
//|                                                                    |
//| Mirrors app/models.py's TradeSetup field-for-field so the EA side |
//| and the Python/backend side agree on the same shape when signals  |
//| cross the WebRequest boundary (EA -> telegram-bridge /signal).    |
//|                                                                    |
//| CORE INVARIANT: invalidation and stop_loss are separate fields.   |
//| invalidation = where the THESIS is wrong (strategy-owned).        |
//| stop_loss    = the actual protective order sent to the broker.    |
//| Example from the handbook: entry 3350, invalidation 3347, SL 3346.|
//| Do not collapse these into one value anywhere in the setup        |
//| engines - that was the specific bug the handbook calls out.       |
//+------------------------------------------------------------------+
#property strict

struct SetupReasons
  {
   string            items[];

   void              Add(const string reason)
     {
      int n = ArraySize(items);
      ArrayResize(items, n + 1);
      items[n] = reason;
     }
  };

struct TradeSetup
  {
   ENUM_ORDER_TYPE   type;
   double            entry_top;
   double            entry_bottom;

   // Strategy thesis boundary - where the IDEA is wrong.
   double            invalidation;

   // Actual executable protective order - where the ORDER exits.
   double            stop_loss;

   double            tp1;
   double            tp2;
   double            final_tp;

   double            confidence;

   datetime          creation_time;
   datetime          expiry_time;
   bool              active;

   SetupReasons      reasons;
   double            calibrated_probability;
   int               calibration_sample;
  };

//+------------------------------------------------------------------+
//| Cheap sanity checks - NOT a substitute for the fail-closed        |
//| execution validation (broker/symbol metadata) that must happen    |
//| separately, immediately before order submission. This only        |
//| catches internally-inconsistent setups before they're even sent.  |
//+------------------------------------------------------------------+
bool ValidateTradeSetupShape(const TradeSetup &setup, string &error_out)
  {
   if(setup.entry_top < setup.entry_bottom)
     {
      error_out = "entry_top must be >= entry_bottom";
      return false;
     }
   if(setup.type == ORDER_TYPE_BUY && setup.stop_loss >= setup.entry_bottom)
     {
      error_out = "BUY stop_loss must be below entry range";
      return false;
     }
   if(setup.type == ORDER_TYPE_SELL && setup.stop_loss <= setup.entry_top)
     {
      error_out = "SELL stop_loss must be above entry range";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Serializes to the JSON body telegram-bridge's POST /signal        |
//| endpoint expects (per its README's documented payload shape).     |
//| Keep this in sync BY HAND with app/models.py and the bridge's     |
//| validator.py - there is no shared schema file across MQL5/Python  |
//| in this repo layout, so a field added on one side silently does   |
//| nothing on the other until both are updated.                      |
//+------------------------------------------------------------------+
string TradeSetupToSignalJson(const string signal_id, const string symbol,
                               const string timeframe, const TradeSetup &setup)
  {
   string direction = (setup.type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   string reasons_json = "[";
   for(int i = 0; i < ArraySize(setup.reasons.items); i++)
     {
      if(i > 0)
         reasons_json += ",";
      reasons_json += "\"" + setup.reasons.items[i] + "\"";
     }
   reasons_json += "]";

   string json = "{";
   json += "\"signal_id\":\"" + signal_id + "\",";
   json += "\"symbol\":\"" + symbol + "\",";
   json += "\"direction\":\"" + direction + "\",";
   json += "\"entry\":" + DoubleToString(setup.entry_bottom, 5) + ",";
   // CORE INVARIANT, preserved across the wire: invalidation (thesis
   // boundary) and sl (protective order) are separate fields here too.
   // This used to be dropped on the floor at this exact serialization
   // step, which quietly defeated the entire point of section 3 the
   // moment a setup left the EA. Do not collapse these back into one.
   json += "\"invalidation\":" + DoubleToString(setup.invalidation, 5) + ",";
   json += "\"sl\":" + DoubleToString(setup.stop_loss, 5) + ",";
   json += "\"tp1\":" + DoubleToString(setup.tp1, 5) + ",";
   json += "\"tp2\":" + DoubleToString(setup.tp2, 5) + ",";
   json += "\"final_tp\":" + DoubleToString(setup.final_tp, 5) + ",";
   json += "\"confidence\":" + DoubleToString(setup.confidence, 1) + ",";
   json += "\"reasons\":" + reasons_json + ",";
   json += "\"timeframe\":\"" + timeframe + "\"";
   json += "}";
   // REQUIRED on the receiving end: telegram-bridge/app/models.py and
   // validator.py must accept `invalidation` and `final_tp` as fields
   // distinct from `sl`/`tp2`, or this fix is a no-op — the bridge will
   // just ignore the new keys. Update both sides together.
   return json;
  }
//+------------------------------------------------------------------+
