//+------------------------------------------------------------------+
//|                                       Execution/BrokerAdapter.mqh |
//+------------------------------------------------------------------+
#ifndef BROKERADAPTER_MQH
#define BROKERADAPTER_MQH

#include <Trade\Trade.mqh>

// Thin wrapper around the standard CTrade class. OrderManager and
// PositionManager never touch the trade API directly — everything routes
// through here, which centralizes retry/error logging and gives one seam
// to swap execution backends later (e.g. a copier API) without touching
// the rest of Execution.
//
// FIXED: market fills used to hand back CTrade::ResultOrder() (the order
// ticket) as the position ticket. That happens to work on a netting
// account, where MT5 keeps one position per symbol, but it is not
// guaranteed to equal the position ticket in general and breaks outright
// on a hedging account with multiple concurrent positions on the same
// symbol. Every deal MT5 executes records which position it belongs to
// (DEAL_POSITION_ID), and that ID is exactly what
// PositionSelectByTicket()/POSITION_TICKET expect — on both account
// modes. MarketBuy/MarketSell now resolve the real position ticket via
// the deal, with the old order-ticket behavior kept only as a logged
// fallback if history lookup ever fails.
class CBrokerAdapter
  {
private:
   CTrade            m_trade;
   int               m_maxRetries;
   int               m_retryDelayMs;
   ulong             m_lastLatencyUs;   // LATENCY: wall time spent inside the most recent broker call, including any retry sleeps

   bool              LastRequestOk(string action);
   ulong             ResolvePositionTicket();
   // LATENCY: not every rejection deserves the same treatment. A requote
   // or a stale price just needs a fresh quote — sleeping the full
   // m_retryDelayMs before asking again is wasted time on something that
   // clears in milliseconds. A connection/timeout issue genuinely needs
   // the network a moment to recover. A terminal rejection (bad stops,
   // no money, trading disabled, market closed) will not change no
   // matter how many times or how fast you retry it — burning the
   // remaining attempts and their delays on it is pure latency with no
   // chance of success. Classify once, act accordingly, in both retry
   // loops below.
   bool              IsRetryable(uint retcode);
   int               DelayForRetcode(uint retcode);

   // G6 FIX: audit of Execution/Portfolio/Trading found magic-number
   // order attribution here, but ZERO checks anywhere for broker
   // stop-distance/freeze-level, connection loss, or market-closed —
   // all three mandatory for a live-trading EA. Before this, the only
   // defense against any of the three was reacting to whatever retcode
   // the broker happened to send back AFTER a doomed request round-trip
   // — no local pre-check ever stopped one from being sent in the
   // first place. Centralized here since every execution call already
   // routes through this class.
   bool              IsConnected();
   bool              IsMarketOpenForTrading(string symbol, bool requireFullOpen);
   bool              ValidateStopDistance(string symbol, double refPrice, double sl, double tp, bool isBuy, string action);

public:
   void              Init(ulong magic, int maxRetries = 3, int retryDelayMs = 300);
   // LATENCY: milliseconds spent inside the most recently completed
   // MarketBuy/MarketSell/PlaceLimit call (success or final failure),
   // including every retry sleep. This is the "execution" half of
   // confirmation+execution latency — call right after any of those
   // three return, before making another broker call.
   double            LastLatencyMs() { return (double)m_lastLatencyUs / 1000.0; }
   // FIX (audit #25): fillPriceOut returns the REAL price CTrade filled at
   // (ResultPrice()), not the theoretical FVG-edge entry the signal was
   // built around. Market execution uses price=0.0 (fill at whatever the
   // market gives), so the two can differ. Everything downstream that
   // assumed "filled at the decision's entry price" (break-even trigger,
   // R-multiple, partial-close trigger) needs this real number instead.
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
// LATENCY: unlisted/unrecognized codes default to retryable at the
// normal delay — conservative on purpose, since treating an unknown
// code as terminal risks silently giving up on something that was
// actually transient, and this list can't claim to be exhaustive across
// every broker's retcode usage.
bool CBrokerAdapter::IsRetryable(uint retcode)
  {
   switch(retcode)
     {
      // Terminal — retrying changes nothing about these.
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
// LATENCY: requote/price-changed/off-quotes just need a fresh tick, not
// a network recovery window — retry almost immediately. Timeout/
// connection/too-many-requests genuinely need the full configured delay
// to have a chance of clearing.
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
// G6 FIX. TERMINAL_CONNECTED is the local terminal's link to the trade
// server — separate from, and checked BEFORE, the retry loop's own
// TRADE_RETCODE_CONNECTION handling (that one reacts to a request that
// WAS sent and failed server-side; this one avoids sending a request at
// all when the terminal already knows it has nothing to send it to). Not
// looped into the retry logic on purpose: a retry loop spinning for a
// few hundred ms within one tick cannot fix a genuinely dead connection
// — OnTick() will get another chance on the next tick regardless.
bool CBrokerAdapter::IsConnected()
  {
   if(TerminalInfoInteger(TERMINAL_CONNECTED)) return true;
   Print("MedisTouch BrokerAdapter: terminal not connected to the trade server — refusing to submit, not retrying (a retry loop can't fix a dead connection within one tick).");
   return false;
  }
//+------------------------------------------------------------------+
// G6 FIX. SYMBOL_TRADE_MODE_DISABLED means no trading at all on this
// symbol right now (exchange holiday, broker maintenance, delisting).
// SYMBOL_TRADE_MODE_CLOSEONLY means new positions/orders are refused
// but existing ones can still be closed or modified — requireFullOpen
// lets closes/modifies past a close-only market while still blocking
// new opens. This is a distinct condition from TRADE_RETCODE_MARKET_CLOSED
// (which is a broker's post-hoc rejection of a request already sent);
// this check catches it beforehand instead of spending a round-trip to
// learn what SymbolInfoInteger already knows locally.
bool CBrokerAdapter::IsMarketOpenForTrading(string symbol, bool requireFullOpen)
  {
   long mode = (long)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED)
     {
      PrintFormat("MedisTouch BrokerAdapter: %s trading is disabled on this symbol right now (SYMBOL_TRADE_MODE_DISABLED) — refusing.", symbol);
      return false;
     }
   if(requireFullOpen && mode == SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      PrintFormat("MedisTouch BrokerAdapter: %s is close-only right now (SYMBOL_TRADE_MODE_CLOSEONLY) — refusing to open a new position/order.", symbol);
      return false;
     }
   return true;
  }
//+------------------------------------------------------------------+
// G6 FIX. Two separate broker-imposed minimums, both expressed in
// points and both meaning "SL/TP must sit at least this far from the
// reference price or the broker will reject it": SYMBOL_TRADE_STOPS_LEVEL
// (minimum distance for placing/modifying a stop) and
// SYMBOL_TRADE_FREEZE_LEVEL (minimum distance within which an order/
// position can't be touched at all, on brokers that impose one).
// MathMax of the two, since either can independently cause a broker
// rejection — some brokers set STOPS_LEVEL, others FREEZE_LEVEL, some
// both, some (real ECN accounts) neither, which is why 0 is left as 0
// rather than defaulted to something nonzero: genuinely means "no
// broker-imposed minimum," not "not configured."
// Also checks SL/TP land on the correct side of the reference price —
// catches a wiring bug elsewhere in this codebase before it reaches the
// broker as a confusing generic rejection, not just a broker-limit
// violation.
bool CBrokerAdapter::ValidateStopDistance(string symbol, double refPrice, double sl, double tp, bool isBuy, string action)
  {
   if(refPrice <= 0.0)
     {
      PrintFormat("MedisTouch BrokerAdapter: %s refused — reference price is %.5f (stale/zero quote), can't validate stop distance against it.", action, refPrice);
      return false;
     }
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0) return true; // can't validate without a point size -- a symbol-info failure unrelated to stops shouldn't block the trade

   long stopsLevelPts  = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPts = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
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
         PrintFormat("MedisTouch BrokerAdapter: %s refused — SL %.5f is %.1f points from reference %.5f, broker requires >= %.1f (stops level %d, freeze level %d).",
                     action, sl, MathAbs(refPrice - sl) / point, refPrice, minDist / point, stopsLevelPts, freezeLevelPts);
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
         PrintFormat("MedisTouch BrokerAdapter: %s refused — TP %.5f is %.1f points from reference %.5f, broker requires >= %.1f (stops level %d, freeze level %d).",
                     action, tp, MathAbs(refPrice - tp) / point, refPrice, minDist / point, stopsLevelPts, freezeLevelPts);
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
   PrintFormat("MedisTouch BrokerAdapter: %s failed, retcode=%d (%s)",
               action, code, m_trade.ResultRetcodeDescription());
   return false;
  }
//+------------------------------------------------------------------+
ulong CBrokerAdapter::ResolvePositionTicket()
  {
   ulong dealTicket = m_trade.ResultDeal();
   if(dealTicket == 0)
     {
      Print("MedisTouch BrokerAdapter: fill had no deal ticket in the trade result, ",
            "falling back to order ticket — verify this position manually.");
      return m_trade.ResultOrder();
     }
   if(!HistoryDealSelect(dealTicket))
     {
      // FIX: this was two separate string-literal arguments after the
      // format string, with only one %d specifier to consume them and
      // dealTicket left as a trailing unmatched argument — a malformed
      // PrintFormat call, not a working one. Concatenated into a single
      // format string with its one real argument.
      PrintFormat("MedisTouch BrokerAdapter: could not select deal #%d from history, falling back to order ticket — verify this position manually.",
                  dealTicket);
      return m_trade.ResultOrder();
     }
   ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(positionId == 0)
     {
      // FIX: same malformed-call shape as above.
      PrintFormat("MedisTouch BrokerAdapter: deal #%d carried no DEAL_POSITION_ID, falling back to order ticket — verify this position manually.",
                  dealTicket);
      return m_trade.ResultOrder();
     }
   return positionId;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::MarketBuy(string symbol, double volume, double sl, double tp, ulong &ticketOut, double &fillPriceOut, string comment)
  {
   fillPriceOut = 0.0;
   // G6 FIX: zero out m_lastLatencyUs on every early refusal below —
   // otherwise LastLatencyMs() would report whatever the PREVIOUS
   // successful/failed broker call took, misleadingly attributed to
   // this call, which never actually reached the broker.
   if(!IsConnected()) { m_lastLatencyUs = 0; return false; }
   if(!IsMarketOpenForTrading(symbol, true)) { m_lastLatencyUs = 0; return false; }
   double refPrice = SymbolInfoDouble(symbol, SYMBOL_ASK); // a market buy fills near the ask
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
      if(!IsRetryable(code)) break; // LATENCY: terminal rejection — stop burning time on retries that can't succeed
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
   double refPrice = SymbolInfoDouble(symbol, SYMBOL_BID); // a market sell fills near the bid
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
   // Distance validated against the resting order's OWN price, not the
   // current market price — that's what the broker measures a pending
   // order's stop distance from.
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
   if(!IsConnected()) return false; // G6 FIX
   if(m_trade.OrderDelete(ticket)) return true;
   LastRequestOk("CancelOrder");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::ModifySLTP(ulong ticket, double sl, double tp)
  {
   if(!IsConnected()) return false; // G6 FIX
   // G6 FIX: this is exactly where SYMBOL_TRADE_FREEZE_LEVEL bites
   // hardest in practice — moving a stop while price sits inside the
   // freeze zone around it is the single most common cause of a
   // real-money break-even/trailing-stop rejection. Needs the
   // position's own symbol and direction to validate against, which
   // this call didn't previously look up at all.
   if(!PositionSelectByTicket(ticket))
     {
      PrintFormat("MedisTouch BrokerAdapter: ModifySLTP refused — position #%d not found/selectable.", ticket);
      return false;
     }
   string symbol = PositionGetString(POSITION_SYMBOL);
   bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double refPrice = isBuy ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK); // the price a close would fill at
   if(!ValidateStopDistance(symbol, refPrice, sl, tp, isBuy, "ModifySLTP")) return false;

   if(m_trade.PositionModify(ticket, sl, tp)) return true;
   LastRequestOk("ModifySLTP");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::ClosePartial(ulong ticket, double volume)
  {
   if(!IsConnected()) return false; // G6 FIX
   if(!PositionSelectByTicket(ticket))
     {
      PrintFormat("MedisTouch BrokerAdapter: ClosePartial refused — position #%d not found/selectable.", ticket);
      return false;
     }
   if(!IsMarketOpenForTrading(PositionGetString(POSITION_SYMBOL), false)) return false; // requireFullOpen=false -- CLOSEONLY is fine for a close, DISABLED still isn't
   if(m_trade.PositionClosePartial(ticket, volume)) return true;
   LastRequestOk("ClosePartial");
   return false;
  }
//+------------------------------------------------------------------+
bool CBrokerAdapter::CloseFull(ulong ticket)
  {
   if(!IsConnected()) return false; // G6 FIX
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
