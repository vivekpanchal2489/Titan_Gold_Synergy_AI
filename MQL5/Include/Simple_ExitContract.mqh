//+------------------------------------------------------------------+
//|                                      Simple_ExitContract.mqh      |
//|                         Break-Even + Trailing Stop + Fast Cut     |
//+------------------------------------------------------------------+
#ifndef SIMPLE_EXIT_CONTRACT
#define SIMPLE_EXIT_CONTRACT

//--- Exit Inputs
input bool   InpUseBreakEven    = true;   // Move SL to breakeven at profit
input double InpBE_Trigger_ATR  = 1.0;    // Move to BE at +1.0x ATR profit
input bool   InpUseTrailing     = true;   // Enable trailing stop
input double InpTrail_ATR       = 1.5;    // Trail at 1.5x ATR behind price
input bool   InpUseFastCut      = true;   // Cut losing trades early
input double InpFastCut_USD     = -12.0;  // Close at -$12 loss

//--- Indicator handle for ATR
int trailATRHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Initialize exit module                                             |
//+------------------------------------------------------------------+
void InitExitModule() {
    trailATRHandle = iATR(_Symbol, PERIOD_M5, 14);
    Print("EXIT MODULE: BE=", InpUseBreakEven ? "ON" : "OFF", 
          " | Trail=", InpUseTrailing ? "ON" : "OFF", 
          " | FastCut=", InpUseFastCut ? "ON" : "OFF");
}

//+------------------------------------------------------------------+
//| Deinitialize exit module                                           |
//+------------------------------------------------------------------+
void DeinitExitModule() {
    if(trailATRHandle != INVALID_HANDLE) {
        IndicatorRelease(trailATRHandle);
    }
}

//+------------------------------------------------------------------+
//| Get current ATR value                                              |
//+------------------------------------------------------------------+
double GetATR() {
    if(trailATRHandle == INVALID_HANDLE) return 0;
    double buf[];
    ArraySetAsSeries(buf, true);
    if(CopyBuffer(trailATRHandle, 0, 0, 1, buf) < 1) return 0;
    return buf[0];
}

//+------------------------------------------------------------------+
//| Manage open position — BE, Trail, Fast Cut                        |
//| Call this from OnTick()                                            |
//+------------------------------------------------------------------+
void ManageOpenPositions() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(PositionGetSymbol(i) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
        
        ulong ticket = PositionGetInteger(POSITION_TICKET);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentTP = PositionGetDouble(POSITION_TP);
        long posType = PositionGetInteger(POSITION_TYPE);
        
        double atr = GetATR();
        if(atr <= 0) continue;
        
        double currentPrice;
        if(posType == POSITION_TYPE_BUY) {
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        } else {
            currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        }
        
        double profit = currentPrice - openPrice;
        if(posType == POSITION_TYPE_SELL) profit = openPrice - currentPrice;
        
        //--- Fast Cut: Close losing trades early
        if(InpUseFastCut) {
            double profitUSD = PositionGetDouble(POSITION_PROFIT);
            if(profitUSD <= InpFastCut_USD) {
                Print("EXIT: Fast Cut @ $", DoubleToString(profitUSD, 2), " | Ticket=", ticket);
                trade.PositionClose(ticket);
                continue;
            }
        }
        
        //--- Break-Even: Move SL to entry + small buffer
        if(InpUseBreakEven) {
            double beTrigger = atr * InpBE_Trigger_ATR;
            double beBuffer = _Point * 10;  // 1 pip buffer
            
            if(posType == POSITION_TYPE_BUY) {
                if(currentPrice >= openPrice + beTrigger && currentSL < openPrice + beBuffer) {
                    double newSL = NormalizeDouble(openPrice + beBuffer, _Digits);
                    trade.PositionModify(ticket, newSL, currentTP);
                    Print("EXIT: Break-Even BUY @ ", newSL, " | Ticket=", ticket);
                }
            }
            else if(posType == POSITION_TYPE_SELL) {
                if(currentPrice <= openPrice - beTrigger && (currentSL > openPrice - beBuffer || currentSL == 0)) {
                    double newSL = NormalizeDouble(openPrice - beBuffer, _Digits);
                    trade.PositionModify(ticket, newSL, currentTP);
                    Print("EXIT: Break-Even SELL @ ", newSL, " | Ticket=", ticket);
                }
            }
        }
        
        //--- Trailing Stop: Lock in profit
        if(InpUseTrailing) {
            double trailDist = atr * InpTrail_ATR;
            
            if(posType == POSITION_TYPE_BUY) {
                double newTrailSL = NormalizeDouble(currentPrice - trailDist, _Digits);
                if(newTrailSL > currentSL && newTrailSL > openPrice) {
                    trade.PositionModify(ticket, newTrailSL, currentTP);
                    Print("EXIT: Trailing BUY SL → ", newTrailSL, " | Ticket=", ticket);
                }
            }
            else if(posType == POSITION_TYPE_SELL) {
                double newTrailSL = NormalizeDouble(currentPrice + trailDist, _Digits);
                if((newTrailSL < currentSL || currentSL == 0) && newTrailSL < openPrice) {
                    trade.PositionModify(ticket, newTrailSL, currentTP);
                    Print("EXIT: Trailing SELL SL → ", newTrailSL, " | Ticket=", ticket);
                }
            }
        }
    }
}

#endif
//+------------------------------------------------------------------+
