//+------------------------------------------------------------------+
//|                                       Execution/BrokerAdapter.mqh |
//+------------------------------------------------------------------+
#ifndef BROKERADAPTER_MQH
#define BROKERADAPTER_MQH

#include <Trade\Trade.mqh>

// Central execution seam: all broker calls, local safety validation and
// broker-call latency measurement live here.
class CBrokerAdapter
  {
private:
   CTrade            m_trade;
   int               m_maxRetries;
   int               m_retryDelayMs;
   ulong             m_lastLatencyUs;

   bool              LastRequestOk(string action);
   ulong             ResolvePositionTicket();
   bool              IsRetryable(uint retcode);
   int               DelayForRetcode(uint retcode);
   bool              IsConnected();
   bool              IsMarketOpenForTrading(string symbol, bool requireFullOpen);
   bool              ValidateStopDistance(string symbol, double refPrice, double sl, double tp, bool isBuy, string action);

public:
   void              Init(ulong magic, int maxRetries = 3, int retryDelayMs = 300);
   double            LastLatencyMs() { return (double)m_lastLatencyUs / 1000.0; }
   bool              MarketBuy(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment = "");
   bool              MarketSell(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment = "");
   bool              PlaceLimit(string symbol, ENUM_ORDER_TYPE type, double volume, double price,
                                double sl, double tp, ulong &ticketOut, string comment = "");
   bool              CancelOrder(ulong ticket);
   bool              ModifySLTP(ulong ticket, double sl, double tp);
   bool              ClosePartial(ulong ticket, double volume);
   bool              CloseFull(ulong ticket);
  };
//+------------------------------------------------------------------+
void CBrokerAdapter::Init(ulong magic, int maxRetries, int retryDelayMs)
  {
   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetDeviationInPoints(20);
   m_trade.SetTypeFillingBySymbol(_Symbol);
   m_maxRetries = maxRetries;
   m_retryDelayMs = retryDelayMs;
   m_lastLatencyUs = 0;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::IsRetryable(uint retcode)
  {
   switch(retcode)
     {
      case TRADE_RETCODE_INVALID_STOPS:
      case TRADE_RETCODE_TRADE_DISABLED:
      case TRADE_RETCODE_MARKET_CLOSED:
      case TRADE_RETCODE_NO_MONEY:
      case TRADE_RETCODE_INVALID_EXPIRATION:
      case TRADE_RETCODE_LOCKED:
      case TRADE_RETCODE_INVALID_FILL:
      case TRADE_RETCODE_ONLY_REAL:
      case TRADE_RETCODE_LIMIT_ORDERS:
      case TRADE_RETCODE_LIMIT_VOLUME:
      case TRADE_RETCODE_INVALID_ORDER:
      case TRADE_RETCODE_LIMIT_POSITIONS:
      case TRADE_RETCODE_LONG_ONLY:
      case TRADE_RETCODE_SHORT_ONLY:
      case TRADE_RETCODE_CLOSE_ONLY:
      case TRADE_RETCODE_FIFO_CLOSE:
      case TRADE_RETCODE_HEDGE_PROHIBITED:
      case TRADE_RETCODE_SERVER_DISABLES_AT:
      case TRADE_RETCODE_CLIENT_DISABLES_AT:
         return false;
      default:
         return true;
     }
  }
//+------------------------------------------------------------------+
int CBrokerAdapter::DelayForRetcode(uint retcode)
  {
   switch(retcode)
     {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
         return MathMin(m_retryDelayMs, 50);
      default:
         return m_retryDelayMs;
     }
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::IsConnected()
  {
   if(TerminalInfoInteger(TERMINAL_CONNECTED)) return true;
   Print("MedisTouch BrokerAdapter: terminal is not connected to the trade server — refusing broker request.");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::IsMarketOpenForTrading(string symbol, bool requireFullOpen)
  {
   long mode = (long)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED)
     {
      PrintFormat("MedisTouch BrokerAdapter: %s trading is disabled — refusing.", symbol);
      return false;
     }
   if(requireFullOpen && mode == SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      PrintFormat("MedisTouch BrokerAdapter: %s is close-only — refusing a new position/order.", symbol);
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
// Fail CLOSED when symbol metadata required for a safety decision is
// unavailable. An unknown point size is not evidence that broker stop
// constraints are absent; it is an inability to validate them.
bool CBrokerAdapter::ValidateStopDistance(string symbol, double refPrice, double sl, double tp, bool isBuy, string action)
  {
   if(refPrice <= 0.0)
     {
      PrintFormat("MedisTouch BrokerAdapter: %s refused — invalid reference price %.5f.", action, refPrice);
      return false;
     }

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
     {
      PrintFormat("MedisTouch BrokerAdapter: %s refused — SYMBOL_POINT unavailable/invalid for %s; cannot validate broker stop distance safely.", action, symbol);
      return false;
     }

   long stopsLevelPts  = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPts = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(stopsLevelPts < 0 || freezeLevelPts < 0)
     {
      PrintFormat("MedisTouch BrokerAdapter: %s refused — invalid broker stop/freeze metadata for %s (stops=%d, freeze=%d).",
                  action, symbol, stopsLevelPts, freezeLevelPts);
      return false;
     }

   double minDist = MathMax(stopsLevelPts, freezeLevelPts) * point;

   if(sl > 0.0)
     {
      bool wrongSide = isBuy ? (sl >= refPrice) : (sl <= refPrice);
      if(wrongSide)
        {
         PrintFormat("MedisTouch BrokerAdapter: %s refused — SL %.5f is on the wrong side of reference %.5f for a %s.",
                     action, sl, refPrice, isBuy ? "buy" : "sell");
         return false;
        }
      if(minDist > 0.0 && MathAbs(refPrice - sl) < minDist)
        {
         PrintFormat("MedisTouch BrokerAdapter: %s refused — SL distance %.1f points < broker minimum %.1f (stops=%d, freeze=%d).",
                     action, MathAbs(refPrice - sl) / point, minDist / point, stopsLevelPts, freezeLevelPts);
         return false;
        }
     }

   if(tp > 0.0)
     {
      bool wrongSide = isBuy ? (tp <= refPrice) : (tp >= refPrice);
      if(wrongSide)
        {
         PrintFormat("MedisTouch BrokerAdapter: %s refused — TP %.5f is on the wrong side of reference %.5f for a %s.",
                     action, tp, refPrice, isBuy ? "buy" : "sell");
         return false;
        }
      if(minDist > 0.0 && MathAbs(refPrice - tp) < minDist)
        {
         PrintFormat("MedisTouch BrokerAdapter: %s refused — TP distance %.1f points < broker minimum %.1f (stops=%d, freeze=%d).",
                     action, MathAbs(refPrice - tp) / point, minDist / point, stopsLevelPts, freezeLevelPts);
         return false;
        }
     }
   return true;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::LastRequestOk(string action)
  {
   uint code = m_trade.ResultRetcode();
   if(code == TRADE_RETCODE_DONE || code == TRADE_RETCODE_PLACED)
      return true;
   PrintFormat("MedisTouch BrokerAdapter: %s failed, retcode=%d (%s)", action, code, m_trade.ResultRetcodeDescription());
   return false;
  }
//+------------------------------------------------------------------+
ulong CBrokerAdapter::ResolvePositionTicket()
  {
   ulong dealTicket = m_trade.ResultDeal();
   if(dealTicket == 0)
      return m_trade.ResultOrder();
   if(!HistoryDealSelect(dealTicket))
     {
      PrintFormat("MedisTouch BrokerAdapter: could not select deal #%d; falling back to order ticket.", dealTicket);
      return m_trade.ResultOrder();
     }
   ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(positionId == 0)
     {
      PrintFormat("MedisTouch BrokerAdapter: deal #%d has no DEAL_POSITION_ID; falling back to order ticket.", dealTicket);
      return m_trade.ResultOrder();
     }
   return positionId;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::MarketBuy(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment)
  {
   fillPriceOut = 0.0;
   if(!IsConnected()) { m_lastLatencyUs = 0; return false; }
   if(!IsMarketOpenForTrading(symbol, true)) { m_lastLatencyUs = 0; return false; }
   double refPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(!ValidateStopDistance(symbol, refPrice, sl, tp, true, "MarketBuy")) { m_lastLatencyUs = 0; return false; }

   ulong t0 = GetMicrosecondCount();
   for(int i = 0; i < m_maxRetries; i++)
     {
      if(m_trade.Buy(volume, symbol, 0.0, sl, tp, comment) && LastRequestOk("MarketBuy"))
        {
         ticketOut = ResolvePositionTicket();
         fillPriceOut = m_trade.ResultPrice();
         m_lastLatencyUs = GetMicrosecondCount() - t0;
         return true;
        }
      uint code = m_trade.ResultRetcode();
      if(!IsRetryable(code)) break;
      Sleep(DelayForRetcode(code));
     }
   m_lastLatencyUs = GetMicrosecondCount() - t0;
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::MarketSell(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment)
  {
   fillPriceOut = 0.0;
   if(!IsConnected()) { m_lastLatencyUs = 0; return false; }
   if(!IsMarketOpenForTrading(symbol, true)) { m_lastLatencyUs = 0; return false; }
   double refPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
   if(!ValidateStopDistance(symbol, refPrice, sl, tp, false, "MarketSell")) { m_lastLatencyUs = 0; return false; }

   ulong t0 = GetMicrosecondCount();
   for(int i = 0; i < m_maxRetries; i++)
     {
      if(m_trade.Sell(volume, symbol, 0.0, sl, tp, comment) && LastRequestOk("MarketSell"))
        {
         ticketOut = ResolvePositionTicket();
         fillPriceOut = m_trade.ResultPrice();
         m_lastLatencyUs = GetMicrosecondCount() - t0;
         return true;
        }
      uint code = m_trade.ResultRetcode();
      if(!IsRetryable(code)) break;
      Sleep(DelayForRetcode(code));
     }
   m_lastLatencyUs = GetMicrosecondCount() - t0;
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::PlaceLimit(string symbol, ENUM_ORDER_TYPE type, double volume, double price,
                                double sl, double tp, ulong &ticketOut, string comment)
  {
   if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT)
     {
      Print("MedisTouch BrokerAdapter: PlaceLimit called with a non-limit order type");
      return false;
     }
   bool isBuy = (type == ORDER_TYPE_BUY_LIMIT);
   if(!IsConnected()) { m_lastLatencyUs = 0; return false; }
   if(!IsMarketOpenForTrading(symbol, true)) { m_lastLatencyUs = 0; return false; }
   if(!ValidateStopDistance(symbol, price, sl, tp, isBuy, "PlaceLimit")) { m_lastLatencyUs = 0; return false; }

   ulong t0 = GetMicrosecondCount();
   for(int i = 0; i < m_maxRetries; i++)
     {
      bool ok = (type == ORDER_TYPE_BUY_LIMIT)
                  ? m_trade.BuyLimit(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment)
                  : m_trade.SellLimit(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      if(ok && LastRequestOk("PlaceLimit"))
        {
         ticketOut = m_trade.ResultOrder();
         m_lastLatencyUs = GetMicrosecondCount() - t0;
         return true;
        }
      uint code = m_trade.ResultRetcode();
      if(!IsRetryable(code)) break;
      Sleep(DelayForRetcode(code));
     }
   m_lastLatencyUs = GetMicrosecondCount() - t0;
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::CancelOrder(ulong ticket)
  {
   if(!IsConnected()) return false;
   if(m_trade.OrderDelete(ticket)) return true;
   LastRequestOk("CancelOrder");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::ModifySLTP(ulong ticket, double sl, double tp)
  {
   if(!IsConnected()) return false;
   if(!PositionSelectByTicket(ticket))
     {
      PrintFormat("MedisTouch BrokerAdapter: ModifySLTP refused — position #%d not found/selectable.", ticket);
      return false;
     }
   string symbol = PositionGetString(POSITION_SYMBOL);
   bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double refPrice = isBuy ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(!ValidateStopDistance(symbol, refPrice, sl, tp, isBuy, "ModifySLTP")) return false;
   if(m_trade.PositionModify(ticket, sl, tp)) return true;
   LastRequestOk("ModifySLTP");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::ClosePartial(ulong ticket, double volume)
  {
   if(!IsConnected()) return false;
   if(!PositionSelectByTicket(ticket))
     {
      PrintFormat("MedisTouch BrokerAdapter: ClosePartial refused — position #%d not found/selectable.", ticket);
      return false;
     }
   if(!IsMarketOpenForTrading(PositionGetString(POSITION_SYMBOL), false)) return false;
   if(m_trade.PositionClosePartial(ticket, volume)) return true;
   LastRequestOk("ClosePartial");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::CloseFull(ulong ticket)
  {
   if(!IsConnected()) return false;
   if(!PositionSelectByTicket(ticket))
     {
      PrintFormat("MedisTouch BrokerAdapter: CloseFull refused — position #%d not found/selectable.", ticket);
      return false;
     }
   if(!IsMarketOpenForTrading(PositionGetString(POSITION_SYMBOL), false)) return false;
   if(m_trade.PositionClose(ticket)) return true;
   LastRequestOk("CloseFull");
   return false;
  }
#endif
//+------------------------------------------------------------------+
