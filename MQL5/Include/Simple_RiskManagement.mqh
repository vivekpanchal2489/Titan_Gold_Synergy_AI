//+------------------------------------------------------------------+
//|                                      Simple_RiskManagement.mqh    |
//|                            Minimal Risk Controls — Daily Limits   |
//+------------------------------------------------------------------+
#ifndef SIMPLE_RISK_MGMT
#define SIMPLE_RISK_MGMT

//--- Risk Inputs
input double InpDailyLossLimit   = 50.0;    // Max daily loss ($)
input double InpMaxDrawdown      = 100.0;   // Max drawdown ($)
input int    InpMaxTradesPerDay  = 6;        // Max trades per day
input double InpMaxLotSize       = 0.50;     // Absolute max lot size

//--- Daily Tracking
double dailyPnL = 0;
int    dailyTrades = 0;
double sessionStartEquity = 0;
datetime lastResetDay = 0;

//+------------------------------------------------------------------+
//| Reset daily counters at midnight                                   |
//+------------------------------------------------------------------+
void ResetDailyCounters() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    datetime today = StringToTime(IntegerToString(dt.year) + "." + 
                                   IntegerToString(dt.mon) + "." + 
                                   IntegerToString(dt.day));
    
    if(today != lastResetDay) {
        dailyPnL = 0;
        dailyTrades = 0;
        sessionStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        lastResetDay = today;
        Print("RISK: Daily counters reset. Equity=", sessionStartEquity);
    }
}

//+------------------------------------------------------------------+
//| Update PnL tracking (call after each trade close)                 |
//+------------------------------------------------------------------+
void UpdateDailyPnL(double tradePnL) {
    dailyPnL += tradePnL;
    dailyTrades++;
    Print("RISK: Daily PnL=", DoubleToString(dailyPnL, 2), " | Trades=", dailyTrades);
}

//+------------------------------------------------------------------+
//| Check if trading is allowed                                        |
//| Returns: true = can trade, false = blocked                        |
//+------------------------------------------------------------------+
bool IsTradingAllowed() {
    ResetDailyCounters();
    
    //--- Daily loss limit
    if(dailyPnL <= -InpDailyLossLimit) {
        Print("BLOCKED: Daily loss limit reached ($", DoubleToString(dailyPnL, 2), ")");
        return false;
    }
    
    //--- Max drawdown
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    double drawdown = sessionStartEquity - currentEquity;
    if(drawdown >= InpMaxDrawdown) {
        Print("BLOCKED: Max drawdown reached ($", DoubleToString(drawdown, 2), ")");
        return false;
    }
    
    //--- Max trades per day
    if(dailyTrades >= InpMaxTradesPerDay) {
        Print("BLOCKED: Max trades per day reached (", dailyTrades, ")");
        return false;
    }
    
    //--- Lot size validation
    // (checked at execution time, not here)
    
    return true;
}

//+------------------------------------------------------------------+
//| Validate lot size                                                   |
//+------------------------------------------------------------------+
bool ValidateLots(double lots) {
    if(lots <= 0 || lots > InpMaxLotSize) {
        Print("BLOCKED: Invalid lot size ", lots, " (max ", InpMaxLotSize, ")");
        return false;
    }
    return true;
}

#endif
//+------------------------------------------------------------------+
