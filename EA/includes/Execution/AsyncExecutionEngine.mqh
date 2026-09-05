//+------------------------------------------------------------------+
//| Execution/AsyncExecutionEngine.mqh                              |
//| Non-blocking request ledger + OrderCheck + OrderSendAsync.       |
//+------------------------------------------------------------------+
#ifndef ASYNCEXECUTIONENGINE_MQH
#define ASYNCEXECUTIONENGINE_MQH

#include <Trade\Trade.mqh>

enum ENUM_MT_EXEC_STATE
  {
   MT_EXEC_NEW=0, MT_EXEC_CHECKED, MT_EXEC_RESERVED, MT_EXEC_SENT,
   MT_EXEC_ACKED, MT_EXEC_PARTIAL, MT_EXEC_FILLED, MT_EXEC_REJECTED,
   MT_EXEC_REQUOTED, MT_EXEC_CANCELLED, MT_EXEC_RECOVERING, MT_EXEC_RECONCILED
  };

struct MTExecutionRequest
  {
   string request_id;
   string signal_id;
   string symbol;
   ENUM_ORDER_TYPE type;
   double volume;
   double price;
   double sl;
   double tp;
   ulong  order_ticket;
   ulong  deal_ticket;
   ulong  position_ticket;
   uint   retcode;
   ENUM_MT_EXEC_STATE state;
   ulong created_us;
   ulong check_us;
   ulong sent_us;
   ulong transaction_us;
   ulong lease_until_us;
  };

class CAsyncExecutionEngine
  {
private:
   MTExecutionRequest m_requests[];
   int m_max_requests;
   int Find(string request_id);
   ulong NowUs();
   string MakeId(string signal_id);
public:
   void Init(int max_requests=128);
   bool Submit(const string signal_id,const string symbol,ENUM_ORDER_TYPE type,double volume,double price,double sl,double tp,string &request_id);
   bool HandleTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result);
   void RecoverExpiredLeases();
   int Size() { return ArraySize(m_requests); }
   ENUM_MT_EXEC_STATE State(const string request_id);
  };

ulong CAsyncExecutionEngine::NowUs()
  {
   return GetMicrosecondCount();
  }

string CAsyncExecutionEngine::MakeId(string signal_id)
  {
   return "MTX-"+signal_id+"-"+IntegerToString((int)NowUs());
  }

void CAsyncExecutionEngine::Init(int max_requests)
  {
   m_max_requests=MathMax(16,max_requests);
   ArrayResize(m_requests,0);
  }

int CAsyncExecutionEngine::Find(string request_id)
  {
   for(int i=0;i<ArraySize(m_requests);i++) if(m_requests[i].request_id==request_id) return i;
   return -1;
  }

bool CAsyncExecutionEngine::Submit(const string signal_id,const string symbol,ENUM_ORDER_TYPE type,double volume,double price,double sl,double tp,string &request_id)
  {
   request_id=MakeId(signal_id);
   if(Find(request_id)>=0 || ArraySize(m_requests)>=m_max_requests) return false;
   MqlTradeRequest req={};
   MqlTradeCheckResult check={};
   req.action=TRADE_ACTION_DEAL;
   req.symbol=symbol;
   req.volume=volume;
   req.type=type;
   req.price=price;
   req.sl=sl;
   req.tp=tp;
   req.deviation=20;
   req.type_filling=ORDER_FILLING_FOK;
   req.comment="MTX:"+request_id;

   MTExecutionRequest row={};
   row.request_id=request_id; row.signal_id=signal_id; row.symbol=symbol;
   row.type=type; row.volume=volume; row.price=price; row.sl=sl; row.tp=tp;
   row.state=MT_EXEC_NEW; row.created_us=NowUs(); row.lease_until_us=row.created_us+30000000;
   ArrayResize(m_requests,ArraySize(m_requests)+1);
   int idx=ArraySize(m_requests)-1;
   m_requests[idx]=row;

   if(!OrderCheck(req,check))
     {
      m_requests[idx].retcode=check.retcode;
      m_requests[idx].state=MT_EXEC_REJECTED;
      return false;
     }
   m_requests[idx].check_us=NowUs();
   m_requests[idx].state=MT_EXEC_CHECKED;
   // Reservation is represented by this unique ledger row before network submission.
   m_requests[idx].state=MT_EXEC_RESERVED;
   m_requests[idx].sent_us=NowUs();
   if(!OrderSendAsync(req,check.retcode==0 ? *(new MqlTradeResult) : *(new MqlTradeResult)))
     {
      // The async API may return false before a server transaction exists.
      m_requests[idx].state=MT_EXEC_REJECTED;
      return false;
     }
   m_requests[idx].state=MT_EXEC_SENT;
   return true;
  }

bool CAsyncExecutionEngine::HandleTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   string rid=request.comment;
   if(StringFind(rid,"MTX:")==0) rid=StringSubstr(rid,4); else return false;
   int idx=Find(rid); if(idx<0) return false;
   if(m_requests[idx].state==MT_EXEC_RECONCILED) return true;
   m_requests[idx].transaction_us=NowUs();
   m_requests[idx].retcode=result.retcode;
   m_requests[idx].order_ticket=trans.order;
   m_requests[idx].deal_ticket=trans.deal;
   m_requests[idx].position_ticket=trans.position;
   if(result.retcode==TRADE_RETCODE_REQUOTE || result.retcode==TRADE_RETCODE_PRICE_CHANGED || result.retcode==TRADE_RETCODE_PRICE_OFF)
      m_requests[idx].state=MT_EXEC_REQUOTED;
   else if(result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL)
      m_requests[idx].state=(result.retcode==TRADE_RETCODE_DONE_PARTIAL ? MT_EXEC_PARTIAL : MT_EXEC_FILLED);
   else if(result.retcode!=0) m_requests[idx].state=MT_EXEC_REJECTED;
   else m_requests[idx].state=MT_EXEC_ACKED;
   m_requests[idx].state=MT_EXEC_RECONCILED;
   return true;
  }

void CAsyncExecutionEngine::RecoverExpiredLeases()
  {
   ulong now=NowUs();
   for(int i=0;i<ArraySize(m_requests);i++)
     if((m_requests[i].state==MT_EXEC_RESERVED || m_requests[i].state==MT_EXEC_SENT || m_requests[i].state==MT_EXEC_ACKED) && now>m_requests[i].lease_until_us)
        m_requests[i].state=MT_EXEC_RECOVERING;
  }

ENUM_MT_EXEC_STATE CAsyncExecutionEngine::State(const string request_id)
  {
   int i=Find(request_id); return i<0 ? MT_EXEC_REJECTED : m_requests[i].state;
  }
#endif
