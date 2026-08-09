//+------------------------------------------------------------------+
//|                                       Decision/DecisionStore.mqh |
//|  Crash-safe CSV persistence for decisions and their executions.   |
//+------------------------------------------------------------------+
// Recovery cannot reconstruct a live trade from broker data alone: the
// broker knows the ticket, volume, SL and TP, but not the setup that
// produced them (entry zone, TP1/TP2 ladder, confidence). This store is
// the missing half. It writes append-only CSV in the terminal's Files
// folder, one pair of files per symbol, and keeps an in-memory mirror so
// FindById()/LoadAll() never touch the disk on the hot path.
//
// Durability choice: every Save() opens, appends, flushes and CLOSES the
// file rather than holding a handle open across ticks. That costs a file
// open per decision (a few per day, not per tick) and buys the guarantee
// the EA depends on - if the terminal is killed the instant after an
// order fills, the decision row is already on disk.
#ifndef DECISIONSTORE_MQH
#define DECISIONSTORE_MQH

#include "../Core/Config.mqh"
#include "TradeDecision.mqh"

#define DECISION_CSV_SEP ";"

class CDecisionStore
  {
private:
   string               m_symbol;
   string               m_decisionsFile;
   string               m_executionsFile;
   TradeDecisionRecord  m_decisions[];
   ExecutionRecord      m_executions[];

   string               SanitizeSymbol(const string s);
   bool                 AppendLine(const string filename, const string line);
   int                  ReadLines(const string filename, string &lines[]);
   string               SerializeDecision(const TradeDecisionRecord &rec);
   bool                 ParseDecision(const string line, TradeDecisionRecord &rec);
   string               SerializeExecution(const ExecutionRecord &rec);
   bool                 ParseExecution(const string line, ExecutionRecord &rec);
   void                 LoadFromDisk();

public:
                        CDecisionStore();
   void                 Init(const string symbol);
   void                 Deinit();

   bool                 Save(const TradeDecisionRecord &rec);
   bool                 SaveExecution(long decisionId, double volume, ulong ticket);

   int                  LoadAll(TradeDecisionRecord &out[]);
   int                  LoadAllExecutions(ExecutionRecord &out[]);
   bool                 FindById(long decisionId, TradeDecisionRecord &out);
   int                  Count() const { return ArraySize(m_decisions); }
  };
//+------------------------------------------------------------------+
CDecisionStore::CDecisionStore() : m_symbol(""), m_decisionsFile(""), m_executionsFile("") {}
//+------------------------------------------------------------------+
// Symbols can contain characters that are illegal in filenames on some
// brokers ("EURUSD.pro", "XAU/USD", "US30-cash"), so normalise rather
// than letting FileOpen fail silently at runtime.
string CDecisionStore::SanitizeSymbol(const string s)
  {
   string out = "";
   for(int i = 0; i < StringLen(s); i++)
     {
      ushort c = StringGetCharacter(s, i);
      bool ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
      out += ok ? ShortToString(c) : "_";
     }
   return (out == "") ? "SYMBOL" : out;
  }
//+------------------------------------------------------------------+
void CDecisionStore::Init(const string symbol)
  {
   m_symbol = (symbol == "") ? _Symbol : symbol;
   string tag = SanitizeSymbol(m_symbol);
   m_decisionsFile  = "MedisTouch_Decisions_" + tag + ".csv";
   m_executionsFile = "MedisTouch_Executions_" + tag + ".csv";
   ArrayFree(m_decisions);
   ArrayFree(m_executions);
   LoadFromDisk();
  }
//+------------------------------------------------------------------+
// Nothing is buffered between calls, so there is no flush to perform.
// Kept as an explicit no-op hook so OnDeinit's contract stays stable if
// batching is ever introduced.
void CDecisionStore::Deinit()
  {
   ArrayFree(m_decisions);
   ArrayFree(m_executions);
  }
//+------------------------------------------------------------------+
bool CDecisionStore::AppendLine(const string filename, const string line)
  {
   int handle = FileOpen(filename, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("MedisTouch DecisionStore: cannot open %s for append (error %d) — this session's decisions will NOT survive a restart.",
                  filename, GetLastError());
      return false;
     }
   FileSeek(handle, 0, SEEK_END);
   FileWriteString(handle, line + "\r\n");
   FileFlush(handle);
   FileClose(handle);
   return true;
  }
//+------------------------------------------------------------------+
int CDecisionStore::ReadLines(const string filename, string &lines[])
  {
   ArrayFree(lines);
   if(!FileIsExist(filename)) return 0;
   int handle = FileOpen(filename, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("MedisTouch DecisionStore: cannot read %s (error %d).", filename, GetLastError());
      return 0;
     }
   int count = 0;
   while(!FileIsEnding(handle))
     {
      string line = FileReadString(handle);
      if(StringLen(line) == 0) continue;
      ArrayResize(lines, count + 1);
      lines[count++] = line;
     }
   FileClose(handle);
   return count;
  }
//+------------------------------------------------------------------+
// Field order is frozen: appending new fields at the END keeps old files
// readable (ParseDecision tolerates a short row), while reordering would
// silently corrupt recovery after an upgrade.
string CDecisionStore::SerializeDecision(const TradeDecisionRecord &rec)
  {
   string parts[13];
   parts[0]  = IntegerToString(rec.decision_id);
   parts[1]  = rec.symbol;
   parts[2]  = IntegerToString((int)rec.setup.type);
   parts[3]  = DoubleToString(rec.setup.entry_top, _Digits);
   parts[4]  = DoubleToString(rec.setup.entry_bottom, _Digits);
   parts[5]  = DoubleToString(rec.setup.stop_loss, _Digits);
   parts[6]  = DoubleToString(rec.setup.tp1, _Digits);
   parts[7]  = DoubleToString(rec.setup.tp2, _Digits);
   parts[8]  = DoubleToString(rec.setup.final_tp, _Digits);
   parts[9]  = DoubleToString(rec.setup.confidence, 2);
   parts[10] = IntegerToString((long)rec.decided_time);
   parts[11] = IntegerToString((int)rec.action);
   parts[12] = rec.reduce_risk ? "1" : "0";

   string line = parts[0];
   for(int i = 1; i < 13; i++) line += DECISION_CSV_SEP + parts[i];
   return line;
  }
//+------------------------------------------------------------------+
bool CDecisionStore::ParseDecision(const string line, TradeDecisionRecord &rec)
  {
   string f[];
   int n = StringSplit(line, StringGetCharacter(DECISION_CSV_SEP, 0), f);
   if(n < 11) return false;   // too short to rebuild a trade from — skip, don't guess

   ZeroMemory(rec);
   rec.decision_id        = (long)StringToInteger(f[0]);
   rec.symbol             = f[1];
   rec.setup.type         = (ENUM_ORDER_TYPE)(int)StringToInteger(f[2]);
   rec.setup.entry_top    = StringToDouble(f[3]);
   rec.setup.entry_bottom = StringToDouble(f[4]);
   rec.setup.stop_loss    = StringToDouble(f[5]);
   rec.setup.tp1          = StringToDouble(f[6]);
   rec.setup.tp2          = StringToDouble(f[7]);
   rec.setup.final_tp     = StringToDouble(f[8]);
   rec.setup.confidence   = StringToDouble(f[9]);
   rec.setup.creation_time = (datetime)StringToInteger(f[10]);
   rec.setup.active       = true;
   rec.confidence         = rec.setup.confidence;
   rec.decided_time       = (datetime)StringToInteger(f[10]);
   rec.action             = (n > 11) ? (ENUM_TRADE_POLICY)(int)StringToInteger(f[11]) : POLICY_EXECUTE_ONLY;
   rec.reduce_risk        = (n > 12) ? (f[12] == "1") : false;
   rec.valid              = true;
   rec.reason             = "restored from " + m_decisionsFile;
   return true;
  }
//+------------------------------------------------------------------+
string CDecisionStore::SerializeExecution(const ExecutionRecord &rec)
  {
   return IntegerToString(rec.decision_id) + DECISION_CSV_SEP +
          DoubleToString(rec.volume, 2) + DECISION_CSV_SEP +
          IntegerToString((long)rec.ticket) + DECISION_CSV_SEP +
          IntegerToString((long)rec.submitted_time);
  }
//+------------------------------------------------------------------+
bool CDecisionStore::ParseExecution(const string line, ExecutionRecord &rec)
  {
   string f[];
   int n = StringSplit(line, StringGetCharacter(DECISION_CSV_SEP, 0), f);
   if(n < 3) return false;
   ZeroMemory(rec);
   rec.decision_id    = (long)StringToInteger(f[0]);
   rec.volume         = StringToDouble(f[1]);
   rec.ticket         = (ulong)StringToInteger(f[2]);
   rec.submitted_time = (n > 3) ? (datetime)StringToInteger(f[3]) : 0;
   return true;
  }
//+------------------------------------------------------------------+
void CDecisionStore::LoadFromDisk()
  {
   string lines[];
   int n = ReadLines(m_decisionsFile, lines);
   for(int i = 0; i < n; i++)
     {
      TradeDecisionRecord rec;
      if(!ParseDecision(lines[i], rec)) continue;
      int idx = ArraySize(m_decisions);
      ArrayResize(m_decisions, idx + 1);
      m_decisions[idx] = rec;
     }

   string elines[];
   int m = ReadLines(m_executionsFile, elines);
   for(int i = 0; i < m; i++)
     {
      ExecutionRecord rec;
      if(!ParseExecution(elines[i], rec)) continue;
      int idx = ArraySize(m_executions);
      ArrayResize(m_executions, idx + 1);
      m_executions[idx] = rec;
     }

   if(n > 0 || m > 0)
      PrintFormat("MedisTouch DecisionStore: loaded %d decision(s) and %d execution(s) for %s.",
                  ArraySize(m_decisions), ArraySize(m_executions), m_symbol);
  }
//+------------------------------------------------------------------+
bool CDecisionStore::Save(const TradeDecisionRecord &rec)
  {
   if(!rec.valid) return false;

   // Idempotent: re-saving the same decision (e.g. after a retry path)
   // must not create a second row Recovery could match twice.
   for(int i = 0; i < ArraySize(m_decisions); i++)
      if(m_decisions[i].decision_id == rec.decision_id) return true;

   int idx = ArraySize(m_decisions);
   ArrayResize(m_decisions, idx + 1);
   m_decisions[idx] = rec;
   return AppendLine(m_decisionsFile, SerializeDecision(rec));
  }
//+------------------------------------------------------------------+
bool CDecisionStore::SaveExecution(long decisionId, double volume, ulong ticket)
  {
   ExecutionRecord rec;
   ZeroMemory(rec);
   rec.decision_id    = decisionId;
   rec.volume         = volume;
   rec.ticket         = ticket;
   rec.submitted_time = TimeCurrent();

   for(int i = 0; i < ArraySize(m_executions); i++)
      if(m_executions[i].decision_id == decisionId && m_executions[i].ticket == ticket) return true;

   int idx = ArraySize(m_executions);
   ArrayResize(m_executions, idx + 1);
   m_executions[idx] = rec;
   return AppendLine(m_executionsFile, SerializeExecution(rec));
  }
//+------------------------------------------------------------------+
int CDecisionStore::LoadAll(TradeDecisionRecord &out[])
  {
   int n = ArraySize(m_decisions);
   ArrayResize(out, n);
   for(int i = 0; i < n; i++) out[i] = m_decisions[i];
   return n;
  }
//+------------------------------------------------------------------+
int CDecisionStore::LoadAllExecutions(ExecutionRecord &out[])
  {
   int n = ArraySize(m_executions);
   ArrayResize(out, n);
   for(int i = 0; i < n; i++) out[i] = m_executions[i];
   return n;
  }
//+------------------------------------------------------------------+
bool CDecisionStore::FindById(long decisionId, TradeDecisionRecord &out)
  {
   for(int i = ArraySize(m_decisions) - 1; i >= 0; i--)
      if(m_decisions[i].decision_id == decisionId)
        {
         out = m_decisions[i];
         return true;
        }
   return false;
  }
#endif
//+------------------------------------------------------------------+
