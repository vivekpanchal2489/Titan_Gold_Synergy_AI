//+------------------------------------------------------------------+
//|                                        GoldEngine_Simple.mq5     |
//|                            The Simple Edge — 3 High-Prob Setups  |
//|                     Liquidity Sweep + Mean Reversion + Breakout  |
//+------------------------------------------------------------------+
#property copyright "Titan Gold AI"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Simple_RiskManagement.mqh>
#include <Simple_EntryGates.mqh>
#include <Simple_ExitContract.mqh>
#include <Simple_Dashboard.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                   |
//+------------------------------------------------------------------+
input group "=== Core Risk ==="
input double InpLots          = 0.10;     // Fixed lot size
input double InpSL_ATR_Mult  = 1.2;      // SL = 1.2x ATR
input double InpTP_ATR_Mult  = 1.8;      // TP = 1.8x ATR (1.5:1 RR)
input int    InpMagicNumber   = 300001;   // Magic number
input int    InpSlippage      = 3;        // Slippage (points)

input group "=== Indicators ==="
input int    InpATR_Period    = 14;       // ATR period
input int    InpRSI_Period    = 14;       // RSI period
input int    InpBB_Period     = 20;       // Bollinger period
input double InpBB_Dev        = 2.0;      // Bollinger deviation

input group "=== Directional Lock ==="
input bool   InpUseDirectionalLock = true; // Enable H1 EMA 50 lock
input int    InpH1_EMA_Period      = 50;   // H1 EMA period

input group "=== Entry Filters ==="
input double InpMinSpread     = 35.0;     // Max spread (points)

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+
CTrade trade;
int handleATR, handleRSI, handleBB, handleADX, handleH1EMA;
datetime lastBarTime = 0;
double asianHigh = 0, asianLow = 0;

// Indicator buffers
double atrBuffer[], rsiBuffer[];
double bbUpper[], bbMiddle[], bbLower[];
double adxBuffer[];
double h1Close[];
long   volumeBuffer[];

//+------------------------------------------------------------------+
//| Helper price functions                                             |
//+------------------------------------------------------------------+
double GetOpen(int shift=1)  { return iOpen(_Symbol, PERIOD_M5, shift); }
double GetClose(int shift=1) { return iClose(_Symbol, PERIOD_M5, shift); }
double GetHigh(int shift=1)  { return iHigh(_Symbol, PERIOD_M5, shift); }
double GetLow(int shift=1)   { return iLow(_Symbol, PERIOD_M5, shift); }

//+------------------------------------------------------------------+
//| Expert initialization                                              |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(InpSlippage);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    
    //--- Create indicator handles
    handleATR   = iATR(_Symbol, PERIOD_M5, InpATR_Period);
    handleRSI   = iRSI(_Symbol, PERIOD_M5, InpRSI_Period, PRICE_CLOSE);
    handleBB    = iBands(_Symbol, PERIOD_M5, InpBB_Period, 0, InpBB_Dev, PRICE_CLOSE);
    handleADX   = iADX(_Symbol, PERIOD_M5, 14);
    handleH1EMA = iMA(_Symbol, PERIOD_H1, InpH1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    
    if(handleATR == INVALID_HANDLE || handleRSI == INVALID_HANDLE ||
       handleBB == INVALID_HANDLE || handleADX == INVALID_HANDLE ||
       handleH1EMA == INVALID_HANDLE) {
        Print("ERROR: Failed to create indicator handles");
        return(INIT_FAILED);
    }
    
    //--- Set series
    ArraySetAsSeries(atrBuffer, true);
    ArraySetAsSeries(rsiBuffer, true);
    ArraySetAsSeries(bbUpper, true);
    ArraySetAsSeries(bbMiddle, true);
    ArraySetAsSeries(bbLower, true);
    ArraySetAsSeries(adxBuffer, true);
    ArraySetAsSeries(h1Close, true);
    ArraySetAsSeries(volumeBuffer, true);
    
    //--- Init modules
    InitExitModule();
    
    Print("============================================");
    Print("GOLDENGINE SIMPLE v3.0 — 3 Rule System");
    Print("============================================");
    Print("Risk: Fixed ", InpLots, " lots | SL: ", InpSL_ATR_Mult, "x ATR | TP: ", InpTP_ATR_Mult, "x ATR");
    Print("Directional Lock: ", InpUseDirectionalLock ? "ON" : "OFF");
    Print("Daily Loss Limit: $", InpDailyLossLimit, " | Max Trades/Day: ", InpMaxTradesPerDay);
    Print("Sessions: London=", InpTradeLondon ? "ON" : "OFF", 
          " | NY=", InpTradeNY ? "ON" : "OFF", 
          " | Asian=", InpTradeAsian ? "ON" : "OFF");
    Print("Exit: BE=", InpUseBreakEven ? "ON" : "OFF", 
          " | Trail=", InpUseTrailing ? "ON" : "OFF", 
          " | FastCut=", InpUseFastCut ? "ON" : "OFF");
    Print("============================================");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    IndicatorRelease(handleATR);
    IndicatorRelease(handleRSI);
    IndicatorRelease(handleBB);
    IndicatorRelease(handleADX);
    IndicatorRelease(handleH1EMA);
    DeinitExitModule();
    CleanDashboard();
}

//+------------------------------------------------------------------+
//| Check H1 Directional Lock                                         |
//| Returns: 1 = BUY allowed, -1 = SELL allowed, 0 = blocked         |
//+------------------------------------------------------------------+
int CheckDirectionalLock() {
    if(!InpUseDirectionalLock) return 0;
    
    if(CopyBuffer(handleH1EMA, 0, 0, 1, h1Close) < 1) return 0;
    
    double h1Price = iClose(_Symbol, PERIOD_H1, 0);
    
    if(h1Price > h1Close[0]) return 1;
    if(h1Price < h1Close[0]) return -1;
    return 0;
}

//+------------------------------------------------------------------+
//| SETUP 1: Liquidity Sweep Reversal                                  |
//| Price sweeps Asian high/low, closes back, high volume             |
//+------------------------------------------------------------------+
int SetupLiquiditySweep() {
    if(asianHigh <= 0 || asianLow <= 0) return 0;
    
    if(CopyTickVolume(_Symbol, PERIOD_M5, 0, 20, volumeBuffer) < 20) return 0;
    
    double volMedian = 0;
    for(int i = 0; i < 20; i++) volMedian += (double)volumeBuffer[i];
    volMedian /= 20.0;
    
    double currentVol = (double)volumeBuffer[0];
    if(volMedian <= 0) return 0;
    
    double high1  = GetHigh(1);
    double low1   = GetLow(1);
    double close1 = GetClose(1);
    
    // SELL: Swept above Asian high, closed back below
    if(high1 > asianHigh && close1 < asianHigh && currentVol > volMedian * 1.5) {
        Print("SETUP: Liquidity SELL — Swept Asian High ", DoubleToString(asianHigh, _Digits));
        return -1;
    }
    
    // BUY: Swept below Asian low, closed back above
    if(low1 < asianLow && close1 > asianLow && currentVol > volMedian * 1.5) {
        Print("SETUP: Liquidity BUY — Swept Asian Low ", DoubleToString(asianLow, _Digits));
        return 1;
    }
    
    return 0;
}

//+------------------------------------------------------------------+
//| SETUP 2: Extreme Mean Reversion                                    |
//| RSI extreme + reversal candle + wick rejection                     |
//+------------------------------------------------------------------+
int SetupMeanReversion() {
    if(CopyBuffer(handleRSI, 0, 1, 1, rsiBuffer) < 1) return 0;
    
    double rsi    = rsiBuffer[0];
    double open1  = GetOpen(1);
    double close1 = GetClose(1);
    double high1  = GetHigh(1);
    double low1   = GetLow(1);
    
    double body = MathAbs(close1 - open1);
    double range = high1 - low1;
    if(range <= 0) return 0;
    
    double lowerWick = (open1 - low1) / range;
    double upperWick = (high1 - close1) / range;
    double bodyRatio = body / range;
    
    // BUY: Extreme oversold + reversal candle + lower wick
    if(rsi < 18 && close1 > open1 && lowerWick > 0.6 && bodyRatio > 0.2) {
        Print("SETUP: Mean Reversion BUY — RSI ", DoubleToString(rsi, 1));
        return 1;
    }
    
    // SELL: Extreme overbought + reversal candle + upper wick
    if(rsi > 82 && close1 < open1 && upperWick > 0.6 && bodyRatio > 0.2) {
        Print("SETUP: Mean Reversion SELL — RSI ", DoubleToString(rsi, 1));
        return -1;
    }
    
    return 0;
}

//+------------------------------------------------------------------+
//| SETUP 3: Breakout After Compression                                |
//| BB squeeze + ADX rising + volume surge                             |
//+------------------------------------------------------------------+
int SetupBreakout() {
    // Buffer 0: Middle line, Buffer 1: Upper line, Buffer 2: Lower line
    if(CopyBuffer(handleBB, 0, 1, 1, bbMiddle) < 1) return 0;
    if(CopyBuffer(handleBB, 1, 1, 1, bbUpper) < 1) return 0;
    if(CopyBuffer(handleBB, 2, 1, 1, bbLower) < 1) return 0;
    if(CopyBuffer(handleADX, 0, 0, 2, adxBuffer) < 2) return 0;
    if(CopyTickVolume(_Symbol, PERIOD_M5, 0, 20, volumeBuffer) < 20) return 0;
    
    // Calculate current BB width
    if(bbMiddle[0] <= 0) return 0;
    double bbWidth = (bbUpper[0] - bbLower[0]) / bbMiddle[0];
    
    // Calculate median BB width over 100 bars
    double tmpUpper[], tmpMiddle[], tmpLower[];
    ArraySetAsSeries(tmpUpper, true);
    ArraySetAsSeries(tmpMiddle, true);
    ArraySetAsSeries(tmpLower, true);
    
    if(CopyBuffer(handleBB, 0, 0, 100, tmpMiddle) < 100) return 0;
    if(CopyBuffer(handleBB, 1, 0, 100, tmpUpper) < 100) return 0;
    if(CopyBuffer(handleBB, 2, 0, 100, tmpLower) < 100) return 0;
    
    double bbWidths[];
    ArrayResize(bbWidths, 100);
    for(int i = 0; i < 100; i++) {
        if(tmpMiddle[i] > 0) bbWidths[i] = (tmpUpper[i] - tmpLower[i]) / tmpMiddle[i];
        else bbWidths[i] = 999;
    }
    ArraySort(bbWidths);
    double bbWidthMedian = bbWidths[50];
    
    double adxNow = adxBuffer[0];
    double adxPrev = adxBuffer[1];
    
    // Volume surge
    double volMedian = 0;
    for(int i = 0; i < 20; i++) volMedian += (double)volumeBuffer[i];
    volMedian /= 20.0;
    double currentVol = (double)volumeBuffer[0];
    
    // Compression check
    if(bbWidth > bbWidthMedian * 0.8) return 0;
    if(adxNow <= 20) return 0;
    if(adxNow <= adxPrev) return 0;
    if(currentVol <= volMedian) return 0;
    
    double close1 = GetClose(1);
    
    // BUY breakout
    if(close1 > bbUpper[0]) {
        Print("SETUP: Breakout BUY — ADX ", DoubleToString(adxNow, 1), " + Vol Surge");
        return 1;
    }
    
    // SELL breakout
    if(close1 < bbLower[0]) {
        Print("SETUP: Breakout SELL — ADX ", DoubleToString(adxNow, 1), " + Vol Surge");
        return -1;
    }
    
    return 0;
}

//+------------------------------------------------------------------+
//| Execute Trade                                                      |
//+------------------------------------------------------------------+
void ExecuteTrade(int direction, string setupName) {
    //--- Risk checks
    if(!IsTradingAllowed()) return;
    if(!IsEntryAllowed(InpMinSpread)) return;
    if(!ValidateLots(InpLots)) return;
    
    //--- Directional lock
    int lock = CheckDirectionalLock();
    if(lock != 0 && lock != direction) {
        Print("BLOCKED: Directional Lock — Price vs H1 EMA 50");
        return;
    }
    
    //--- ATR for SL/TP
    if(CopyBuffer(handleATR, 0, 0, 1, atrBuffer) < 1) return;
    double atr = atrBuffer[0];
    if(atr <= 0) return;
    
    double slPoints = atr * InpSL_ATR_Mult;
    double tpPoints = atr * InpTP_ATR_Mult;
    double price, sl, tp;
    
    if(direction == 1) {
        price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        sl = NormalizeDouble(price - slPoints, _Digits);
        tp = NormalizeDouble(price + tpPoints, _Digits);
        
        if(trade.Buy(InpLots, _Symbol, price, sl, tp, setupName)) {
            Print("EXECUTED: BUY ", InpLots, " @ ", price, " | SL: ", sl, " | TP: ", tp, " | ", setupName);
        } else {
            Print("ERROR: Buy failed — ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
        }
    }
    else if(direction == -1) {
        price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        sl = NormalizeDouble(price + slPoints, _Digits);
        tp = NormalizeDouble(price - tpPoints, _Digits);
        
        if(trade.Sell(InpLots, _Symbol, price, sl, tp, setupName)) {
            Print("EXECUTED: SELL ", InpLots, " @ ", price, " | SL: ", sl, " | TP: ", tp, " | ", setupName);
        } else {
            Print("ERROR: Sell failed — ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
        }
    }
}

//+------------------------------------------------------------------+
//| Track Asian Session High/Low                                       |
//+------------------------------------------------------------------+
void UpdateAsianSession() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    
    static int lastAsianDay = -1;
    if(dt.day != lastAsianDay && dt.hour >= 8) {
        double high = 0, low = 999999;
        
        for(int i = 0; i < 96; i++) {
            double h = iHigh(_Symbol, PERIOD_M5, i);
            double l = iLow(_Symbol, PERIOD_M5, i);
            if(h > high) high = h;
            if(l < low && l > 0) low = l;
        }
        
        if(high > 0 && low < 999999) {
            asianHigh = high;
            asianLow = low;
            lastAsianDay = dt.day;
            Print("ASIAN SESSION: High=", DoubleToString(asianHigh, _Digits), " Low=", DoubleToString(asianLow, _Digits));
        }
    }
    
    if(asianHigh <= 0 || asianLow <= 0) {
        double high = 0, low = 999999;
        for(int i = 0; i < 96; i++) {
            double h = iHigh(_Symbol, PERIOD_M5, i);
            double l = iLow(_Symbol, PERIOD_M5, i);
            if(h > high) high = h;
            if(l < low && l > 0) low = l;
        }
        if(high > 0 && low < 999999) {
            asianHigh = high;
            asianLow = low;
        }
    }
}

//+------------------------------------------------------------------+
//| Count open positions for this EA                                   |
//+------------------------------------------------------------------+
int CountPositions() {
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(PositionGetSymbol(i) == _Symbol) {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick() {
    //--- Manage open positions (BE, Trail, Fast Cut)
    ManageOpenPositions();
    
    //--- Only process entry on new bar
    datetime currentBar = iTime(_Symbol, PERIOD_M5, 0);
    if(currentBar == lastBarTime) return;
    lastBarTime = currentBar;
    
    //--- Update Asian session
    UpdateAsianSession();
    
    //--- Need Asian levels
    if(asianHigh <= 0 || asianLow <= 0) return;
    
    //--- Only 1 position at a time
    if(CountPositions() > 0) return;
    
    //--- Try each setup in priority order
    int direction = 0;
    string setupName = "";
    
    // Priority 1: Liquidity Sweep (highest probability)
    direction = SetupLiquiditySweep();
    if(direction != 0) {
        setupName = "Liquidity Sweep";
    }
    
    // Priority 2: Mean Reversion
    if(direction == 0) {
        direction = SetupMeanReversion();
        if(direction != 0) {
            setupName = "Mean Reversion";
        }
    }
    
    // Priority 3: Breakout
    if(direction == 0) {
        direction = SetupBreakout();
        if(direction != 0) {
            setupName = "Breakout";
        }
    }
    
    //--- Execute
    if(direction != 0) {
        ExecuteTrade(direction, setupName);
    }
    
    //--- Update dashboard
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    DrawDashboard(dailyPnL, dailyTrades, GetCurrentSession(), CountPositions(), equity);
}
//+------------------------------------------------------------------+
