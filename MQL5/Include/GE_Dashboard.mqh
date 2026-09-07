//+------------------------------------------------------------------+
//| GE_Dashboard.mqh                                                  |
//| EXACT AUTHENTIC TITAN V2 DASHBOARD (1:1 COPY FROM TITAN V2)       |
//+------------------------------------------------------------------+
#ifndef GE_DASHBOARD_MQH
#define GE_DASHBOARD_MQH

enum ENUM_DB_POSITION
{
   DB_POS_TOP_LEFT,      // Top Left
   DB_POS_TOP_RIGHT,     // Top Right
   DB_POS_BOTTOM_LEFT,   // Bottom Left
   DB_POS_BOTTOM_RIGHT,  // Bottom Right
   DB_POS_CENTER,        // Center
   DB_POS_FREE_MOVE      // Free Move (Drag panel to move)
};

input group "=== Titan V2 Dashboard UI Settings ==="
input bool             InpShowDashboard      = true;               // Show Dashboard Panel
input ENUM_DB_POSITION InpDashboardPosition  = DB_POS_TOP_LEFT;     // Dashboard Position Mode
input int              InpDashboardX         = 20;                 // Custom X Offset
input int              InpDashboardY         = 45;                 // Custom Y Offset
input int              InpDashboardWidth     = 1260;               // Dashboard Width (Expanded for perfect high-DPI text fitting)
input int              InpDashboardHeight    = 495;                // Dashboard Height

//--- Object naming
#define DB_PREFIX     "GE_Sentinel_DB_"
#define DB_BG         "DbPanelBg"
#define DB_TITLE      "DbTitle"
#define DB_ROW(i)     DB_PREFIX + "R" + IntegerToString(i)
#define DB_MAXROWS    11
#define DB_KILL_BTN   DB_PREFIX + "KillBtn"

//--- Global variables read by dashboard
bool   g_dashKillSwitchActive   = false;
bool   g_dashCurfewActive       = false;
string g_dashRegimeMode         = "SIDEWAYS";
double g_dashADX                = 0.0;
double g_dashATR                = 0.0;
string g_dashOnnxClass          = "N/A";
double g_dashOnnxProb           = 0.0;
double g_dashOnnxMargin         = 0.0;

// History + Next action variables
double g_dashOnnxBull1  = 0.0;
double g_dashOnnxBear1  = 0.0;
bool   g_dashOnnxValid1 = false;
double g_dashOnnxBull2  = 0.0;
double g_dashOnnxBear2  = 0.0;
bool   g_dashOnnxValid2 = false;
string g_dashNextAction = "";
bool   g_dashHasOpenPosition    = false;
int    g_dashOpenPosCount       = 0;
string g_dashPosType            = "";
double g_dashPosLots            = 0.0;
double g_dashPosEntry           = 0.0;
double g_dashPosSL              = 0.0;
double g_dashPosTP              = 0.0;
double g_dashPosPL              = 0.0;
int    g_dashTradesToday        = 0;
int    g_dashWinsToday          = 0;
int    g_dashLossesToday        = 0;
double g_dashNetPLToday         = 0.0;
string g_dashLastAttemptTime    = "";
string g_dashLastAttemptResult  = "NONE";
string g_dashLastBlockSource    = "";
string g_dashLastBlockReason    = "";
string g_dashLastBlockDetail    = "";

// Geometry & drag memory
int g_dashPanelX = 0, g_dashPanelY = 0, g_dashPanelW = 0, g_dashPanelH = 0;
int g_dbX = -1;
int g_dbY = -1;
bool g_isDragging = false;
int  g_dragStartX = 0, g_dragStartY = 0;
int  g_panelOrigX = 0, g_panelOrigY = 0;

//+------------------------------------------------------------------+
//| Graphics Helpers                                                 |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, int fontSize, color clr, string font="Segoe UI")
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 10);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
}

void CreatePanelBg(string name, int x, int y, int width, int height, color bgColor, color borderColor)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, borderColor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
}

void CreateButton(string name, int x, int y, int width, int height, string text, int fontSize, color clr, color bgColor, string font="Segoe UI Semibold")
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void DashboardDeinit()
{
   ObjectDelete(0, DB_BG);
   ObjectDelete(0, DB_TITLE);
   ObjectDelete(0, DB_KILL_BTN);
   for(int i = 0; i < DB_MAXROWS; i++)
      ObjectDelete(0, DB_ROW(i));
   ChartRedraw(0);
}

bool DashboardPointIsCovered(int x, int y)
{
   if(!InpShowDashboard) return false;
   return (x >= g_dashPanelX && x <= (g_dashPanelX + g_dashPanelW) &&
           y >= g_dashPanelY && y <= (g_dashPanelY + g_dashPanelH));
}

//--- helper dynamic array push
void ArrayAdd(string &arr[], string value)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = value;
}

//+------------------------------------------------------------------+
//| GetCurrentSessionString                                          |
//+------------------------------------------------------------------+
string GetCurrentSessionString()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;

   if(h >= 13 && h < 17) return "London/NY Overlap (Peak Volatility)";
   if(h >= 8 && h < 13)  return "London Active (High Volume)";
   if(h >= 17 && h < 22) return "New York Active (Normal Volume)";
   if(h >= 0 && h < 8)   return "Tokyo Active (Low Volume Cooldown)";
   if(h >= 8 && h < 9)   return "Tokyo/London Overlap (Mid Volume)";
   return "Sydney / Asian Session (Low Volume)";
}

//+------------------------------------------------------------------+
//| CreateInterface — Exact Titan V2 1:1 Layout                      |
//+------------------------------------------------------------------+
void CreateInterface()
{
   if(!InpShowDashboard)
   {
      DashboardDeinit();
      ChartRedraw(0);
      return;
   }

   DashboardDeinit();

   int panelWidth  = InpDashboardWidth;
   int panelHeight = InpDashboardHeight;
   int margin      = 25;

   int chartWidth  = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int chartHeight = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);

   int baseX = InpDashboardX;
   int baseY = InpDashboardY;

   if(g_dbX >= 0 || g_dbY >= 0)
   {
      baseX = g_dbX;
      baseY = g_dbY;
   }
   else
   {
      switch(InpDashboardPosition)
      {
         case DB_POS_TOP_LEFT:     baseX = InpDashboardX; baseY = InpDashboardY; break;
         case DB_POS_TOP_RIGHT:    baseX = chartWidth - panelWidth - InpDashboardX; baseY = InpDashboardY; break;
         case DB_POS_BOTTOM_LEFT:  baseX = InpDashboardX; baseY = chartHeight - panelHeight - InpDashboardY - 40; break;
         case DB_POS_BOTTOM_RIGHT: baseX = chartWidth - panelWidth - InpDashboardX; baseY = chartHeight - panelHeight - InpDashboardY - 40; break;
         case DB_POS_CENTER:       baseX = (chartWidth - panelWidth) / 2; baseY = (chartHeight - panelHeight) / 2; break;
         case DB_POS_FREE_MOVE:    baseX = InpDashboardX; baseY = InpDashboardY; break;
      }
      g_dbX = baseX;
      g_dbY = baseY;
   }

   int textX = baseX + margin;
   int fontSize = 10;

   // 1. Titan V2 Shield
   CreatePanelBg(DB_BG, baseX, baseY, panelWidth, panelHeight, C'0,0,0', C'60,60,60');
   CreateLabel(DB_TITLE, textX, baseY + 18, "TITAN QUANTUM SENTINEL AI — 48-FEATURE MASTER NEURAL ENGINE", 12, C'255,179,0', "Segoe UI Semibold");

   string btnText = g_killSwitchBtnActive ? "HALTED" : "RUNNING";
   color btnBg = g_killSwitchBtnActive ? C'239,83,80' : C'76,175,80';
   CreateButton(DB_KILL_BTN, baseX + panelWidth - 165, baseY + 12, 140, 26, btnText, 9, clrWhite, btnBg);

   for(int i = 0; i < DB_MAXROWS; i++)
   {
      int rowY = baseY + 56 + (i * 36);
      CreateLabel(DB_ROW(i), textX, rowY, "", fontSize, clrWhite, "Segoe UI");
   }

   g_dashPanelX = baseX;
   g_dashPanelY = baseY;
   g_dashPanelW = panelWidth;
   g_dashPanelH = panelHeight;

   ChartRedraw(0);
}

void DashboardInit()
{
   CreateInterface();
   DashboardRefresh();
}

//+------------------------------------------------------------------+
//| ShortenReason — Compact, clean reason formatter for HUD HUD      |
//+------------------------------------------------------------------+
string ShortenReason(const string rawReason, const string rawDetail)
{
   if(rawReason == "VOLATILITY_SHOCK") return "Volatility Shock / News Spike";
   if(rawReason == "FALLING_KNIFE") return "Falling Knife (Waiting for Green M5)";
   if(rawReason == "RISING_SURGE") return "Rising Surge (Waiting for Red M5)";
   if(rawReason == "OVEREXTENSION_CHASE") return "Overextended Chasing Guard";
   if(rawReason == "LIQUIDATION_CASCADE")
   {
      if(StringFind(rawDetail, "red") >= 0) return "Red Liquidation Cascade (3+ red bars)";
      if(StringFind(rawDetail, "green") >= 0) return "Green Pump Surge (3+ green bars)";
      return "Liquidation Cascade Veto";
   }
   if(rawReason == "GNN_BOUNDARY")
   {
      if(StringFind(rawDetail, "Ceiling") >= 0) return "Near Golden Ceiling Resistance";
      if(StringFind(rawDetail, "Floor") >= 0) return "Near Aqua Floor Support";
      return "Near GNN Boundary Level";
   }
   if(rawReason == "CONCURRENCY_CAP") return "Max Concurrent Trades Reached";
   if(rawReason == "ANTI_AVERAGING_DOWN") return "Anti-Averaging (Position in Drawdown)";
   if(rawReason == "SAME_DIR_CAP") return "Max Directional Positions Reached";
   if(rawReason == "DIRECTIONAL_LOCK") return "Directional Lock Active";
   if(rawReason == "OPP_DIR_COOLDOWN") return "Opposite Direction Cooldown";
   if(rawReason == "PRICE_ZONE") return "Outside Daily Trading Zone";
   if(rawReason == "EMA_TREND_FILTER") return "Opposes Trend (EMA Filter)";
   if(rawReason == "MTF_TREND_FILTER") return "Opposes Macro Trend (H1 EMA 50)";
   if(rawReason == "RSI_EXHAUSTION") return "RSI Exhaustion";
   if(rawReason == "CANDLE_CONFIRM") return "Waiting for Candle Color Confirm";
   if(rawReason == "ONNX_DISAGREE") return "AI Conviction Below Threshold";
   if(rawReason == "KILL_SWITCH_ACTIVE") return "Kill Switch Active";
   if(rawReason == "ENTRY_CURFEW") return "Entry Curfew Active (until 3:30 AM IST)";
   if(rawReason == "NEWS_FILTER")
   {
      if(StringFind(rawDetail, "News:") >= 0)
      {
         int p = StringFind(rawDetail, "News:");
         string evt = StringSubstr(rawDetail, p + 5);
         StringTrimLeft(evt);
         return StringFormat("High-Impact News: %s", evt);
      }
      return "High-Impact USD News Event";
   }
   if(rawReason == "RISK_CAP_UNHONORED") return "Risk Ceiling / Margin Limit Exceeded";
   if(rawReason == "ORDER_REJECTED") return "Broker Order Send Rejected";

   // Fallback formatting: if rawDetail is clean, strip any timestamps and format nicely
   if(StringLen(rawDetail) > 0)
   {
      string clean = rawDetail;
      int bStart = StringFind(clean, "[");
      int bEnd   = StringFind(clean, "]");
      if(bStart >= 0 && bEnd > bStart)
      {
         clean = StringSubstr(clean, 0, bStart) + StringSubstr(clean, bEnd + 1);
         StringTrimLeft(clean);
      }
      return clean;
   }
   if(StringLen(rawReason) > 0) return rawReason;
   return "None";
}

//+------------------------------------------------------------------+
//| DashboardRefresh — Exact Titan V2 1:1 Telemetry Refresh          |
//+------------------------------------------------------------------+
void DashboardRefresh()
{
   if(!InpShowDashboard) return;
   if(ObjectFind(0, DB_BG) < 0) CreateInterface();

   string btnText = g_killSwitchBtnActive ? "HALTED" : "RUNNING";
   color btnBg = g_killSwitchBtnActive ? C'239,83,80' : C'76,175,80';
   if(ObjectGetString(0, DB_KILL_BTN, OBJPROP_TEXT) != btnText)
      ObjectSetString(0, DB_KILL_BTN, OBJPROP_TEXT, btnText);
   if(ObjectGetInteger(0, DB_KILL_BTN, OBJPROP_BGCOLOR) != btnBg)
      ObjectSetInteger(0, DB_KILL_BTN, OBJPROP_BGCOLOR, btnBg);

   string lines[];
   ArrayResize(lines, 0);

   // Row 0: Operational Status & Dynamic Capital Tier
   int capTier = 1;
   double allocatedCap = GetAllocatedTradingCapital(capTier);
   string activeNewsEvent = "";
   bool isNewsActive = (InpUseNewsFilter && IsHighImpactNewsActive(activeNewsEvent));

   if(g_dashKillSwitchActive)
      ArrayAdd(lines, "Status         : TRADING PAUSED (Kill Switch)");
   else if(g_dashCurfewActive)
      ArrayAdd(lines, "Status         : CURFEW ACTIVE (Paused until 3:30 AM IST)");
   else if(isNewsActive)
      ArrayAdd(lines, StringFormat("Status         : NEWS PAUSE ACTIVE (%s)", activeNewsEvent));
   else
      ArrayAdd(lines, StringFormat("Status         : SENTINEL AI ACTIVE | Regime: %s | Cap: $%.0f (Tier %d) | Max: %d Trades", (g_currentMarketRegime == REGIME_TREND ? "TREND" : (g_currentMarketRegime == REGIME_HIGH_VOL ? "HIGH_VOL" : "CHOP")), allocatedCap, capTier, InpMaxConcurrentTrades));

   // Row 1: Current IST Clock & Active Zone
   MqlDateTime dtIST;
   GetISTDateTime(dtIST);
   string ampm = (dtIST.hour >= 12) ? "PM" : "AM";
   int displayHour = dtIST.hour % 12;
   if(displayHour == 0) displayHour = 12;
   string istTimeStr = StringFormat("%02d:%02d:%02d %s", displayHour, dtIST.min, dtIST.sec, ampm);

   double activeConf = 0.0, activeMargin = 0.0;
   string activeZoneName = "", activeZoneSched = "";
   GetActiveConvictionSettings(activeConf, activeMargin, activeZoneName, activeZoneSched);
   ArrayAdd(lines, StringFormat("Current IST    : %s | Zone: %s", istTimeStr, activeZoneName));

   // Row 2: Conviction Lock
   ArrayAdd(lines, StringFormat("Conviction Lock: %s (Conf ≥ %.2f | Margin ≥ %.2f)", activeZoneSched, activeConf, activeMargin));

   // Row 3: Global Session
   ArrayAdd(lines, StringFormat("Global Market  : %s", GetCurrentSessionString()));

   // Row 4: Time Left on M5 Candle Sync
   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   datetime nextBarTime    = currentBarTime + PeriodSeconds(PERIOD_M5);
   int secsLeft            = (int)(nextBarTime - TimeCurrent());
   if(secsLeft < 0) secsLeft = 0;
   ArrayAdd(lines, StringFormat("Time Left      : %02d:%02d (M5 Candle Sync)", secsLeft / 60, secsLeft % 60));

   // Row 5: Live Position & Active Execution Status
   if(g_dashHasOpenPosition)
   {
      string liveActionStr = (StringLen(g_dashNextAction) > 0 ? g_dashNextAction : "SCANNING");
      ArrayAdd(lines, StringFormat("Live Position  : %d %s (%.2f lots) | Net: %s$%.2f | Next: %s",
                                   g_dashOpenPosCount, g_dashPosType, g_dashPosLots, (g_dashPosPL >= 0 ? "+" : ""), g_dashPosPL, liveActionStr));
   }
   else
   {
      string liveActionStr = (StringLen(g_dashNextAction) > 0 ? g_dashNextAction : "HUNTING A+ SETUP");
      ArrayAdd(lines, StringFormat("Live Position  : FLAT (0 Open) | Next: %s", liveActionStr));
   }

   // Row 6: Last Evaluated Bar Attempt (Short & Concise, No timestamp)
   if(g_dashLastAttemptResult == "BLOCKED")
   {
      string shortReason = ShortenReason(g_dashLastBlockReason, g_dashLastBlockDetail);
      ArrayAdd(lines, StringFormat("Last Attempt   : BLOCKED — %s", shortReason));
   }
   else if(g_dashLastAttemptResult == "PLACED")
   {
      ArrayAdd(lines, StringFormat("Last Attempt   : PLACED — %s", g_dashLastBlockDetail));
   }
   else
   {
      ArrayAdd(lines, "Last Attempt   : NONE (Monitoring M5 Closes)");
   }

   // Row 7: ONNX Consensus Probabilities
   if(g_cachedOnnxValid)
   {
      double pBull = g_cachedOnnxBull;
      double pBear = g_cachedOnnxBear;
      double pNeu  = 1.0 - (pBull + pBear);
      if(pNeu < 0.0) pNeu = 0.0;
      string leadClass = (pBull > pBear) ? "BULL" : "BEAR";
      double leadProb = MathMax(pBull, pBear);
      double gap = g_cachedOnnxMargin;
      string otherProbs = (leadClass == "BULL") ? StringFormat("(Neu: %.1f%%, Bear: %.1f%%)", pNeu * 100.0, pBear * 100.0) :
                          (leadClass == "BEAR") ? StringFormat("(Bull: %.1f%%, Neu: %.1f%%)", pBull * 100.0, pNeu * 100.0) :
                                                 StringFormat("(Bull: %.1f%%, Bear: %.1f%%)", pBull * 100.0, pNeu * 100.0);
      ArrayAdd(lines, StringFormat("Consensus      : %s %.1f%% | +%.3f %s", leadClass, leadProb * 100.0, gap, otherProbs));
   }
   else
   {
      ArrayAdd(lines, "Consensus      : INITIALIZING NEURAL PIPELINE...");
   }

   // Row 8: Historical Momentum M5[-1] & M5[-2]
   string hist1Str = "N/A";
   if(g_histOnnxValid1)
   {
      string h1Class = (g_histOnnxBull1 > g_histOnnxBear1 ? "BULL" : "BEAR");
      double h1Prob = MathMax(g_histOnnxBull1, g_histOnnxBear1) * 100.0;
      hist1Str = StringFormat("%s %.1f%%", h1Class, h1Prob);
   }
   string hist2Str = "N/A";
   if(g_histOnnxValid2)
   {
      string h2Class = (g_histOnnxBull2 > g_histOnnxBear2 ? "BULL" : "BEAR");
      double h2Prob = MathMax(g_histOnnxBull2, g_histOnnxBear2) * 100.0;
      hist2Str = StringFormat("%s %.1f%%", h2Class, h2Prob);
   }
   ArrayAdd(lines, StringFormat("ONNX Momentum  : M5[-1]: %s | M5[-2]: %s", hist1Str, hist2Str));

   // Row 9: Macro H1 Trend Filter & Dynamic Trail
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   static int mtfEmaH = INVALID_HANDLE;
   if(mtfEmaH == INVALID_HANDLE)
      mtfEmaH = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   double mtfEmaVal = 0.0;
   if(mtfEmaH != INVALID_HANDLE)
   {
      double buf[1];
      if(CopyBuffer(mtfEmaH, 0, 0, 1, buf) > 0) mtfEmaVal = buf[0];
   }
   string macroRegime = (price >= mtfEmaVal) ? "BULLISH (H1 EMA 50)" : "BEARISH (H1 EMA 50)";
   ArrayAdd(lines, StringFormat("Macro & Trail  : %s | Dynamic Trail ($10/$15 Lock)", macroRegime));

   // Row 10: Real-Time Today's Performance Tally
   string signStr = (g_dashNetPLToday >= 0.0 ? "+" : "");
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double pnlPct = (balance > 0.0) ? (g_dashNetPLToday / balance) * 100.0 : 0.0;
   ArrayAdd(lines, StringFormat("Today's Tally  : %d Trades (W:%d L:%d) | Net: %s$%.2f (%.2f%%)",
                                g_dashTradesToday, g_dashWinsToday, g_dashLossesToday, signStr, g_dashNetPLToday, pnlPct));

   int n = MathMin(ArraySize(lines), DB_MAXROWS);
   for(int i = 0; i < n; i++)
   {
      string text = lines[i];
      if(ObjectGetString(0, DB_ROW(i), OBJPROP_TEXT) != text)
         ObjectSetString(0, DB_ROW(i), OBJPROP_TEXT, text);

      color rowColor = clrWhite;
      if(i == 0)      rowColor = (g_dashKillSwitchActive || g_dashCurfewActive) ? C'239,83,80' : C'76,175,80';
      else if(i == 1) rowColor = C'255,224,130'; // IST Clock (Gold)
      else if(i == 2) rowColor = C'200,230,201'; // Conviction Lock (Light Green)
      else if(i == 3) rowColor = C'144,202,249'; // Global Market (Light Blue)
      else if(i == 4) rowColor = clrWhite;      // Time Left
      else if(i == 5) // Live Position
      {
         if(g_dashHasOpenPosition) rowColor = C'255,179,0';
         else if(StringFind(lines[i], "PAUSE") >= 0 || StringFind(lines[i], "LOW") >= 0 || StringFind(lines[i], "WAIT") >= 0) rowColor = C'255,152,0';
         else rowColor = C'0,255,255';
      }
      else if(i == 6) // Last Attempt
      {
         if(StringFind(lines[i], "PLACED") >= 0)      rowColor = C'76,175,80';  // Green
         else if(StringFind(lines[i], "BLOCKED") >= 0) rowColor = C'239,83,80'; // Coral / Red
         else                                         rowColor = C'180,180,180';
      }
      else if(i == 7) // ONNX Consensus
      {
         if(g_cachedOnnxBull > g_cachedOnnxBear)      rowColor = C'0,255,255';
         else if(g_cachedOnnxBear > g_cachedOnnxBull) rowColor = C'255,165,0';
         else                                         rowColor = C'150,150,150';
      }
      else if(i == 8) rowColor = clrWhite;       // ONNX Momentum
      else if(i == 9) // Macro & Trail
      {
         if(StringFind(macroRegime, "BULL") >= 0)      rowColor = C'129,199,132';
         else if(StringFind(macroRegime, "BEAR") >= 0) rowColor = C'239,83,80';
         else                                          rowColor = C'255,202,40';
      }
      else if(i == 10) // Today's Tally
      {
         rowColor = (g_dashNetPLToday >= 0.0) ? C'129,199,132' : C'239,83,80';
      }

      ObjectSetInteger(0, DB_ROW(i), OBJPROP_COLOR, rowColor);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| DashboardOnChartEvent — Mouse Click & Free Move Dragging Engine  |
//+------------------------------------------------------------------+
void DashboardOnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(!InpShowDashboard) return;

   // 1. Button Click: Kill Switch
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == DB_KILL_BTN)
      {
         g_killSwitchBtnActive = !g_killSwitchBtnActive;
         PrintFormat("[HUD] User toggled Kill Switch -> %s", (g_killSwitchBtnActive ? "HALTED" : "RUNNING"));
         DashboardRefresh();
      }
   }

   // 2. Free Move Dragging
   if(InpDashboardPosition == DB_POS_FREE_MOVE)
   {
      if(id == CHARTEVENT_CLICK)
      {
         int mouseX = (int)lparam;
         int mouseY = (int)dparam;

         if(mouseX >= g_dashPanelX && mouseX <= (g_dashPanelX + g_dashPanelW) &&
            mouseY >= g_dashPanelY && mouseY <= (g_dashPanelY + g_dashPanelH))
         {
            g_isDragging = !g_isDragging;
            if(g_isDragging)
            {
               g_dragStartX = mouseX;
               g_dragStartY = mouseY;
               g_panelOrigX = g_dashPanelX;
               g_panelOrigY = g_dashPanelY;
            }
         }
         else
         {
            g_isDragging = false;
         }
      }
      else if(id == CHARTEVENT_MOUSE_MOVE && g_isDragging)
      {
         int curX = (int)lparam;
         int curY = (int)dparam;
         int deltaX = curX - g_dragStartX;
         int deltaY = curY - g_dragStartY;

         g_dbX = g_panelOrigX + deltaX;
         g_dbY = g_panelOrigY + deltaY;

         CreateInterface();
         DashboardRefresh();
      }
   }
}

#endif // GE_DASHBOARD_MQH
