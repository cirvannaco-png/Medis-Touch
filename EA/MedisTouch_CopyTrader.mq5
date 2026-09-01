//+------------------------------------------------------------------+
//| MedisTouch_CopyTrader.mq5                                         |
//| Subscriber EA: polls only currently-valid entitled copy events.   |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#include <Trade/Trade.mqh>

input string InpBridgeURL = "https://YOUR-SERVICE.onrender.com/commerce";
input string InpAPIKey = "";
input string InpAccountId = "";
input int    InpPollSeconds = 1;
input int    InpWebRequestTimeoutMs = 2500;
input bool   InpAllowNewSymbol = true;

CTrade g_trade;
string g_processed[];

string JsonString(const string json,const string key)
  {
   string needle="\""+key+"\":\""; int p=StringFind(json,needle); if(p<0)return ""; p+=StringLen(needle);
   int e=StringFind(json,"\"",p); return e>p?StringSubstr(json,p,e-p):"";
  }
double JsonDouble(const string json,const string key)
  {
   string needle="\""+key+\":"; int p=StringFind(json,needle); if(p<0)return 0.0; p+=StringLen(needle);
   int e=p; int n=StringLen(json); while(e<n && StringFind("0123456789.-",StringSubstr(json,e,1))>=0)e++;
   return StringToDouble(StringSubstr(json,p,e-p));
  }
bool Seen(const string id)
  { for(int i=0;i<ArraySize(g_processed);i++)if(g_processed[i]==id)return true; return false; }
void Remember(const string id)
  { int n=ArraySize(g_processed); ArrayResize(g_processed,n+1); g_processed[n]=id; if(n>200){for(int i=1;i<ArraySize(g_processed);i++)g_processed[i-1]=g_processed[i];ArrayResize(g_processed,200);} }

double LotForPercent(string symbol,double riskPct,double entry,double sl)
  {
   if(riskPct<=0 || entry<=0 || sl<=0 || MathAbs(entry-sl)<=0)return 0;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY); double money=equity*riskPct/100.0;
   double loss=0.0; ENUM_ORDER_TYPE t=(entry>sl?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   if(!OrderCalcProfit(t,symbol,1.0,entry,sl,loss))return 0;
   loss=MathAbs(loss); if(loss<=0)return 0;
   double raw=money/loss; double minLot=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN), maxLot=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX), step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(step<=0)return 0; raw=MathFloor(raw/step)*step; if(raw<minLot)return 0; return MathMin(raw,maxLot);
  }

bool PostAck(const string copyId,const string status,const string ticket,const string errorText)
  {
   string url=InpBridgeURL+"/ack"; string body="{\"copy_id\":\""+copyId+"\",\"status\":\""+status+"\",\"broker_ticket\":\""+ticket+"\",\"error_message\":\""+errorText+"\"}";
   char data[],result[]; StringToCharArray(body,data,0,StringLen(body)); string headers="Content-Type: application/json\r\nX-API-Key: "+InpAPIKey+"\r\n";
   string rh; int code=WebRequest("POST",url,headers,InpWebRequestTimeoutMs,data,result,rh); return code>=200 && code<300;
  }

void Poll()
  {
   if(InpAPIKey=="" || InpAccountId=="")return;
   string url=InpBridgeURL+"/poll/"+InpAccountId; char data[],result[]; string rh;
   string headers="X-API-Key: "+InpAPIKey+"\r\n";
   int code=WebRequest("GET",url,headers,InpWebRequestTimeoutMs,data,result,rh); if(code<200||code>=300)return;
   string json=CharArrayToString(result); string copyId=JsonString(json,"copy_id"); if(copyId==""||Seen(copyId))return;
   string symbol=JsonString(json,"symbol"); string direction=JsonString(json,"direction"); double sl=JsonDouble(json,"sl"),tp1=JsonDouble(json,"tp1"),tp2=JsonDouble(json,"tp2"),risk=JsonDouble(json,"risk_value");
   string riskMode=JsonString(json,"risk_mode"); if(symbol==""||sl<=0||tp1<=0||tp2<=0)return;
   if(!InpAllowNewSymbol && symbol!=_Symbol)return;
   if(!SymbolSelect(symbol,true)) { PostAck(copyId,"failed","","Symbol unavailable"); return; }
   double ask=SymbolInfoDouble(symbol,SYMBOL_ASK),bid=SymbolInfoDouble(symbol,SYMBOL_BID); if(ask<=0||bid<=0)return;
   double entry=(direction=="BUY"?ask:bid); double lots=(riskMode=="percent"?LotForPercent(symbol,risk,entry,sl):risk);
   if(lots<=0){PostAck(copyId,"skipped","","Risk size below broker minimum or invalid");Remember(copyId);return;}
   g_trade.SetTypeFillingBySymbol(symbol); bool ok=false;
   if(direction=="BUY")ok=g_trade.Buy(lots,symbol,0,sl,tp2,"MT-COPY "+copyId);
   else if(direction=="SELL")ok=g_trade.Sell(lots,symbol,0,sl,tp2,"MT-COPY "+copyId);
   if(ok){ulong ticket=g_trade.ResultOrder(); PostAck(copyId,"executed",(string)ticket,"");Remember(copyId);}
   else {PostAck(copyId,"failed","",g_trade.ResultRetcodeDescription());}
  }

int OnInit()
  { EventSetTimer(MathMax(1,InpPollSeconds)); return INIT_SUCCEEDED; }
void OnDeinit(const int reason) { EventKillTimer(); }
void OnTimer() { Poll(); }
//+------------------------------------------------------------------+
