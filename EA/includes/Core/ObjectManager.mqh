//+------------------------------------------------------------------+
//|                                             Core/ObjectManager.mqh |
//+------------------------------------------------------------------+
#ifndef OBJECTMANAGER_MQH
#define OBJECTMANAGER_MQH

#include <Arrays\ArrayString.mqh>

// FIX: previously every caller had to manually type "Medis_" into every
// object name, and m_prefix was never actually applied inside Create*().
// That made the prefix decorative — any missed literal would silently
// leak objects that ClearAll()/ClearPrefix() could never find. Now every
// Create*() call takes a short KEY and this class owns prefixing.
class CObjectManager
  {
private:
   string            m_prefix;
   CArrayString      m_objectNames;

   bool              ObjectExists(string name);
   string            FullName(string key) { return m_prefix + key; }

public:
                     CObjectManager(string prefix = "Medis_");
                    ~CObjectManager();

   void              ClearAll();
   void              ClearPrefix(string subPrefix);
   void              RemoveExpiredObjects(datetime olderThan);

   // Creation helpers — 'key' is the short name; full chart object name is m_prefix+key
   bool              CreateTrendLine(string key, datetime t1, double p1, datetime t2, double p2, color clr, int width, int style);
   bool              CreateRectangle(string key, datetime t1, double p1, datetime t2, double p2, color clr, int width, bool fill, int style = STYLE_SOLID);
   bool              CreateLabel(string key, datetime t, double p, string text, color clr, int fontSize, string font = "Arial");
   bool              CreateArrow(string key, datetime t, double p, uchar code, color clr, int size);

   // Update helpers
   bool              SetObjectText(string key, string text);
   bool              SetObjectColor(string key, color clr);
   bool              MoveObject(string key, datetime t, double p);
   string            NameOf(string key) { return FullName(key); } // for callers that need OBJPROP_* access
  };
//+------------------------------------------------------------------+
//| Constructor / Destructor                                          |
//+------------------------------------------------------------------+
CObjectManager::CObjectManager(string prefix)
  {
   m_prefix = prefix;
   m_objectNames.Clear();
  }
CObjectManager::~CObjectManager()
  {
   ClearAll();
  }
//+------------------------------------------------------------------+
bool CObjectManager::ObjectExists(string name)
  {
   return ObjectFind(0, name) >= 0;
  }
//+------------------------------------------------------------------+
void CObjectManager::ClearAll()
  {
   ObjectsDeleteAll(0, m_prefix);
   m_objectNames.Clear();
  }
//+------------------------------------------------------------------+
void CObjectManager::ClearPrefix(string subPrefix)
  {
   ObjectsDeleteAll(0, m_prefix + subPrefix);
  }
//+------------------------------------------------------------------+
void CObjectManager::RemoveExpiredObjects(datetime olderThan)
  {
   for(int i = m_objectNames.Total() - 1; i >= 0; i--)
     {
      string name = m_objectNames.At(i);
      if(!ObjectExists(name))
        {
         m_objectNames.Delete(i);
         continue;
        }
      datetime ot = (datetime)ObjectGetInteger(0, name, OBJPROP_TIME, 0);
      if(ot < olderThan)
        {
         ObjectDelete(0, name);
         m_objectNames.Delete(i);
        }
     }
  }
//+------------------------------------------------------------------+
bool CObjectManager::CreateTrendLine(string key, datetime t1, double p1, datetime t2, double p2, color clr, int width, int style)
  {
   string name = FullName(key);
   if(ObjectExists(name))
      ObjectDelete(0, name);
   bool res = ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   if(res)
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      m_objectNames.Add(name);
     }
   return res;
  }
//+------------------------------------------------------------------+
bool CObjectManager::CreateRectangle(string key, datetime t1, double p1, datetime t2, double p2, color clr, int width, bool fill, int style)
  {
   string name = FullName(key);
   if(ObjectExists(name))
      ObjectDelete(0, name);
   bool res = ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   if(res)
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      if(fill)
         ObjectSetInteger(0, name, OBJPROP_FILL, true);
      m_objectNames.Add(name);
     }
   return res;
  }
//+------------------------------------------------------------------+
bool CObjectManager::CreateLabel(string key, datetime t, double p, string text, color clr, int fontSize, string font)
  {
   string name = FullName(key);
   if(ObjectExists(name))
      ObjectDelete(0, name);
   bool res = ObjectCreate(0, name, OBJ_TEXT, 0, t, p);
   if(res)
     {
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
      ObjectSetString(0, name, OBJPROP_FONT, font);
      m_objectNames.Add(name);
     }
   return res;
  }
//+------------------------------------------------------------------+
bool CObjectManager::CreateArrow(string key, datetime t, double p, uchar code, color clr, int size)
  {
   string name = FullName(key);
   if(ObjectExists(name))
      ObjectDelete(0, name);
   bool res = ObjectCreate(0, name, OBJ_ARROW, 0, t, p);
   if(res)
     {
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, size);
      m_objectNames.Add(name);
     }
   return res;
  }
//+------------------------------------------------------------------+
bool CObjectManager::SetObjectText(string key, string text)
  {
   string name = FullName(key);
   if(!ObjectExists(name)) return false;
   return ObjectSetString(0, name, OBJPROP_TEXT, text);
  }
bool CObjectManager::SetObjectColor(string key, color clr)
  {
   string name = FullName(key);
   if(!ObjectExists(name)) return false;
   return ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }
bool CObjectManager::MoveObject(string key, datetime t, double p)
  {
   string name = FullName(key);
   if(!ObjectExists(name)) return false;
   return ObjectMove(0, name, 0, t, p);
  }
#endif
//+------------------------------------------------------------------+
