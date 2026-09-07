//+------------------------------------------------------------------+
//|                                      Simple_Dashboard.mqh        |
//|                         On-Chart Dashboard — Live Telemetry       |
//+------------------------------------------------------------------+
#ifndef SIMPLE_DASHBOARD
#define SIMPLE_DASHBOARD

//--- Dashboard Inputs
input bool   InpShowDashboard = true;   // Show on-chart dashboard
input color  InpColorBG       = C'20,20,30';    // Background
input color  InpColorText     = clrWhite;        // Text
input color  InpColorGreen    = clrLime;         // Profit
input color  InpColorRed      = clrRed;          // Loss
input color  InpColorYellow   = clrGold;         // Neutral
input int    InpDashboardX    = 10;              // X position
input int    InpDashboardY    = 30;              // Y position

//+------------------------------------------------------------------+
//| Draw dashboard                                                     |
//+------------------------------------------------------------------+
void DrawDashboard(double pnlVal, int tradesCount, string session, 
                   int openPositions, double equity) {
    if(!InpShowDashboard) return;
    
    int x = InpDashboardX;
    int y = InpDashboardY;
    int lineH = 18;
    
    //--- Background
    ObjectCreate(0, "Dash_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, "Dash_BG", OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, "Dash_BG", OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, "Dash_BG", OBJPROP_XSIZE, 220);
    ObjectSetInteger(0, "Dash_BG", OBJPROP_YSIZE, lineH * 9 + 10);
    ObjectSetInteger(0, "Dash_BG", OBJPROP_BGCOLOR, InpColorBG);
    ObjectSetInteger(0, "Dash_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, "Dash_BG", OBJPROP_BORDER_COLOR, clrGray);
    
    //--- Title
    DrawLabel("Dash_Title", x + 5, y + 5, "GOLDENGINE SIMPLE v3.0", InpColorYellow, 9);
    
    //--- Session
    DrawLabel("Dash_Session", x + 5, y + lineH + 8, "Session: " + session, InpColorText, 8);
    
    //--- Equity
    DrawLabel("Dash_Equity", x + 5, y + lineH*2 + 8, 
              "Equity: $" + DoubleToString(equity, 2), InpColorText, 8);
    
    //--- Daily PnL
    color pnlColor = pnlVal >= 0 ? InpColorGreen : InpColorRed;
    DrawLabel("Dash_PnL", x + 5, y + lineH*3 + 8, 
              "Daily PnL: $" + DoubleToString(pnlVal, 2), pnlColor, 8);
    
    //--- Trades
    DrawLabel("Dash_Trades", x + 5, y + lineH*4 + 8, 
              "Trades Today: " + IntegerToString(tradesCount), InpColorText, 8);
    
    //--- Open Positions
    DrawLabel("Dash_Positions", x + 5, y + lineH*5 + 8, 
              "Open Positions: " + IntegerToString(openPositions), InpColorText, 8);
    
    //--- Spread
    double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    color spreadColor = spread > 35 ? InpColorRed : InpColorGreen;
    DrawLabel("Dash_Spread", x + 5, y + lineH*6 + 8, 
              "Spread: " + DoubleToString(spread, 0), spreadColor, 8);
    
    //--- ATR
    double atr = 0;
    int atrH = iATR(_Symbol, PERIOD_M5, 14);
    if(atrH != INVALID_HANDLE) {
        double buf[];
        ArraySetAsSeries(buf, true);
        if(CopyBuffer(atrH, 0, 0, 1, buf) >= 1) atr = buf[0];
        IndicatorRelease(atrH);
    }
    DrawLabel("Dash_ATR", x + 5, y + lineH*7 + 8, 
              "ATR(14): " + DoubleToString(atr, _Digits), InpColorText, 8);
    
    //--- Time
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    string timeStr = IntegerToString(dt.hour) + ":" + 
                     (dt.min < 10 ? "0" : "") + IntegerToString(dt.min) + ":" +
                     (dt.sec < 10 ? "0" : "") + IntegerToString(dt.sec);
    DrawLabel("Dash_Time", x + 5, y + lineH*8 + 8, timeStr, InpColorYellow, 8);
}

//+------------------------------------------------------------------+
//| Helper: Draw a label                                               |
//+------------------------------------------------------------------+
void DrawLabel(string name, int x, int y, string text, color clr, int fontSize) {
    ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Clean up dashboard objects                                         |
//+------------------------------------------------------------------+
void CleanDashboard() {
    ObjectDelete(0, "Dash_BG");
    ObjectDelete(0, "Dash_Title");
    ObjectDelete(0, "Dash_Session");
    ObjectDelete(0, "Dash_Equity");
    ObjectDelete(0, "Dash_PnL");
    ObjectDelete(0, "Dash_Trades");
    ObjectDelete(0, "Dash_Positions");
    ObjectDelete(0, "Dash_Spread");
    ObjectDelete(0, "Dash_ATR");
    ObjectDelete(0, "Dash_Time");
}

#endif
//+------------------------------------------------------------------+
