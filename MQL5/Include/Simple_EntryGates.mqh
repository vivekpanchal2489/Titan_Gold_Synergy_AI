//+------------------------------------------------------------------+
//|                                      Simple_EntryGates.mqh        |
//|                         Minimal Entry Filters — Spread + Session  |
//+------------------------------------------------------------------+
#ifndef SIMPLE_ENTRY_GATES
#define SIMPLE_ENTRY_GATES

//--- Session Time Inputs (Server Time / UTC)
input bool   InpTradeAsian  = false;  // Trade Asian session (00:00-08:00)
input bool   InpTradeLondon = true;   // Trade London session (08:00-16:00)
input bool   InpTradeNY     = true;   // Trade NY session (13:00-21:00)
input bool   InpTradeOverlap = true;  // Trade London-NY overlap (13:00-16:00)

//+------------------------------------------------------------------+
//| Get current session name                                           |
//+------------------------------------------------------------------+
string GetCurrentSession() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;
    
    if(hour >= 0 && hour < 8)   return "Asian";
    if(hour >= 8 && hour < 13)  return "London";
    if(hour >= 13 && hour < 16) return "London-NY Overlap";
    if(hour >= 16 && hour < 21) return "NY";
    return "Off-Hours";
}

//+------------------------------------------------------------------+
//| Check if current session allows trading                            |
//+------------------------------------------------------------------+
bool IsSessionAllowed() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;
    
    // Asian session
    if(hour >= 0 && hour < 8) return InpTradeAsian;
    
    // London session
    if(hour >= 8 && hour < 13) return InpTradeLondon;
    
    // London-NY overlap
    if(hour >= 13 && hour < 16) return InpTradeOverlap;
    
    // NY session
    if(hour >= 16 && hour < 21) return InpTradeNY;
    
    // Off hours
    return false;
}

//+------------------------------------------------------------------+
//| Check if spread is acceptable                                      |
//+------------------------------------------------------------------+
bool IsSpreadOK(double maxSpread) {
    double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    
    if(spread > maxSpread) {
        Print("BLOCKED: Spread ", DoubleToString(spread, 0), " > Max ", DoubleToString(maxSpread, 0));
        return false;
    }
    return true;
}

//+------------------------------------------------------------------+
//| Check if price is near round number (avoid)                        |
//+------------------------------------------------------------------+
bool IsNearRoundNumber(double price, double bufferPoints) {
    // Check if within buffer of round numbers
    double round10 = MathMod(price, 10.0);
    double round50 = MathMod(price, 50.0);
    double round100 = MathMod(price, 100.0);
    
    if(round10 < bufferPoints || round10 > (10.0 - bufferPoints)) return true;
    if(round50 < bufferPoints || round50 > (50.0 - bufferPoints)) return true;
    if(round100 < bufferPoints || round100 > (100.0 - bufferPoints)) return true;
    
    return false;
}

//+------------------------------------------------------------------+
//| Master entry gate — combines all filters                           |
//| Returns: true = allowed, false = blocked                          |
//+------------------------------------------------------------------+
bool IsEntryAllowed(double maxSpread) {
    //--- Session check
    if(!IsSessionAllowed()) {
        Print("BLOCKED: Session ", GetCurrentSession(), " not allowed");
        return false;
    }
    
    //--- Spread check
    if(!IsSpreadOK(maxSpread)) return false;
    
    return true;
}

#endif
//+------------------------------------------------------------------+
