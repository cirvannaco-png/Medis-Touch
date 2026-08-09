//+------------------------------------------------------------------+
//|                                   Signals/SubscriberPlatform.mqh |
//+------------------------------------------------------------------+
#ifndef SUBSCRIBERPLATFORM_MQH
#define SUBSCRIBERPLATFORM_MQH

// Subscriber registry + delivery bookkeeping for the Signal Distribution
// Engine. Deliberately file-based and hand-editable rather than a UI:
// MQL5 has no admin panel to build one without a much bigger investment
// (a web dashboard talking to this over HTTP), and a flat CSV a human —
// or a future admin tool — edits directly is enough to unblock "actually
// send signals to real subscribers" today.
//
// File format, "MedisTouch_Subscribers.csv" (ACCOUNT-WIDE, not
// per-symbol — one subscriber list serves every symbol this EA runs on):
//   SubscriberID, Name, Tier, Endpoint, Active
// Tier is a free-text label (e.g. "FREE", "PRO") — CSignalPublisher
// decides what tier sees what; this class only stores and serves the
// registry, it doesn't gate content by tier itself.
struct Subscriber
  {
   string            id;
   string            name;
   string            tier;
   string            endpoint;
   bool              active;
  };

class CSubscriberPlatform
  {
private:
   string            m_subsFilename;
   string            m_deliveryFilename;
   int               m_deliveryFileHandle;
   Subscriber        m_subscribers[];

   void              LoadSubscribers();

public:
   void              Init();
   void              Deinit();
   void              Reload(); // re-read the subscriber file on demand — it's hand-edited, not written by this class
   int               GetActiveSubscribers(Subscriber &out[]);
   int               GetActiveSubscribers(string tierFilter, Subscriber &out[]); // "" = all tiers
   void              RecordDelivery(string subscriberId, long decisionId, bool success);
   int               Count() { return ArraySize(m_subscribers); }
  };
//+------------------------------------------------------------------+
void CSubscriberPlatform::Init()
  {
   m_subsFilename = "MedisTouch_Subscribers.csv";
   m_deliveryFilename = "MedisTouch_Deliveries.csv";
   LoadSubscribers();

   bool exists = FileIsExist(m_deliveryFilename);
   m_deliveryFileHandle = FileOpen(m_deliveryFilename, FILE_READ | FILE_WRITE | FILE_CSV, ',');
   if(m_deliveryFileHandle == INVALID_HANDLE)
      Print("MedisTouch SubscriberPlatform: could not open ", m_deliveryFilename);
   else if(!exists)
     {
      FileWrite(m_deliveryFileHandle, "SubscriberID", "DecisionID", "Success", "Time");
      FileFlush(m_deliveryFileHandle);
     }
  }
//+------------------------------------------------------------------+
void CSubscriberPlatform::LoadSubscribers()
  {
   ArrayResize(m_subscribers, 0);
   if(!FileIsExist(m_subsFilename))
     {
      // Ship an empty-but-present file with a header so the format is
      // discoverable without documentation. First run, zero subscribers,
      // Publish() below just has nothing to iterate — that's correct.
      int h = FileOpen(m_subsFilename, FILE_WRITE | FILE_CSV, ',');
      if(h != INVALID_HANDLE)
        {
         FileWrite(h, "SubscriberID", "Name", "Tier", "Endpoint", "Active");
         FileClose(h);
        }
      return;
     }

   int handle = FileOpen(m_subsFilename, FILE_READ | FILE_CSV, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("MedisTouch SubscriberPlatform: could not open ", m_subsFilename);
      return;
     }

   if(!FileIsEnding(handle))
      for(int c = 0; c < 5 && !FileIsEnding(handle); c++)
         FileReadString(handle); // skip header row

   int n = 0;
   while(!FileIsEnding(handle))
     {
      string id = FileReadString(handle);
      if(StringLen(id) == 0 && FileIsEnding(handle)) break; // trailing blank line guard

      Subscriber s;
      s.id       = id;
      s.name     = FileReadString(handle);
      s.tier     = FileReadString(handle);
      s.endpoint = FileReadString(handle);
      string activeStr = FileReadString(handle);
      s.active = (activeStr == "1" || activeStr == "true" || activeStr == "TRUE");

      ArrayResize(m_subscribers, n + 1);
      m_subscribers[n++] = s;
     }
   FileClose(handle);
   PrintFormat("MedisTouch SubscriberPlatform: loaded %d subscriber(s) from %s.", n, m_subsFilename);
  }
//+------------------------------------------------------------------+
void CSubscriberPlatform::Reload() { LoadSubscribers(); }
//+------------------------------------------------------------------+
void CSubscriberPlatform::Deinit()
  {
   if(m_deliveryFileHandle != INVALID_HANDLE) FileClose(m_deliveryFileHandle);
  }
//+------------------------------------------------------------------+
int CSubscriberPlatform::GetActiveSubscribers(Subscriber &out[])
  {
   return GetActiveSubscribers("", out);
  }
//+------------------------------------------------------------------+
int CSubscriberPlatform::GetActiveSubscribers(string tierFilter, Subscriber &out[])
  {
   ArrayResize(out, 0);
   int n = 0;
   for(int i = 0; i < ArraySize(m_subscribers); i++)
     {
      if(!m_subscribers[i].active) continue;
      if(tierFilter != "" && m_subscribers[i].tier != tierFilter) continue;
      ArrayResize(out, n + 1);
      out[n++] = m_subscribers[i];
     }
   return n;
  }
//+------------------------------------------------------------------+
void CSubscriberPlatform::RecordDelivery(string subscriberId, long decisionId, bool success)
  {
   if(m_deliveryFileHandle == INVALID_HANDLE) return;
   FileSeek(m_deliveryFileHandle, 0, SEEK_END);
   FileWrite(m_deliveryFileHandle, subscriberId, decisionId, success ? 1 : 0,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   FileFlush(m_deliveryFileHandle);
  }
#endif
//+------------------------------------------------------------------+
