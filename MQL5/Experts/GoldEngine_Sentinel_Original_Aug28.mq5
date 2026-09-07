//+------------------------------------------------------------------+
//| GoldEngine_Sentinel.mq5                                          |
//| Fresh rebuild — Step 5 Addition: labeled/adjustable inputs       |
//| Orchestration only. All logic and inputs live in GE_* modules.   |
//+------------------------------------------------------------------+
#property copyright "GoldEngine Sentinel — Original Aug 27/28 Winning Build"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Modular includes — single responsibility per file. One-directional
//| dependency order (Step 6 addendum): Risk -> Exit -> Entry -> AI ->
//| DecisionLog -> Dashboard. No file includes a lower file (no cycles).
//+------------------------------------------------------------------+
#include <GE_RiskManagement.mqh>
#include <GE_ExitContract.mqh>
#include <GE_EntryGates.mqh>
#include <GE_AIIntegration.mqh>
#include <GE_DecisionLog.mqh>
#include <GE_OutcomeTracker.mqh>
#include <GE_Dashboard.mqh>

//+------------------------------------------------------------------+
//| GNN Structural Lines (spec 09d) — drawn from the mq5 because the  |
//| dashboard include order is Dashboard last; it can still use       |
//| DashboardPointIsCovered() to suppress labels under the panel.     |
//+------------------------------------------------------------------+
input group "=== GNN Structural Lines ==="
input color InpGnnUpperLineColor = clrOrange;  // Resistance tier line color (above price)
input color InpGnnLowerLineColor = clrAqua;    // Support tier line color (below price)
input int   InpGnnLineWidth      = 1;          // Line thickness (pixels)
input bool  InpShowGnnLineLabels = true;       // Show small "R1"/"S1" label at each line

//+------------------------------------------------------------------+
//| SyncDashboardState — copy the real caches (owned by EntryGates /  |
//| DecisionLog) into the g_dash* read-only proxies the dashboard     |
//| consumes. NO decision logic; pure state mirroring.               |
//+------------------------------------------------------------------+
void SyncDashboardState()
{
   g_dashKillSwitchActive = (InpKillSwitch || g_killSwitchBtnActive);
   g_dashRegimeMode       = g_cachedRegime;
   g_dashADX              = g_cachedAdx;
   g_dashATR              = g_cachedAtr;
   g_cachedRsi            = DashRSI(0); // Update live RSI value on every tick

   if(g_cachedOnnxValid)
   {
      g_dashOnnxClass   = (g_cachedOnnxBull > g_cachedOnnxBear ? "BULL" : "BEAR");
      g_dashOnnxProb    = MathMax(g_cachedOnnxBull, g_cachedOnnxBear);
      g_dashOnnxMargin  = g_cachedOnnxMargin;
   }
   else
   {
      g_dashOnnxClass   = "N/A";
      g_dashOnnxProb    = 0.0;
      g_dashOnnxMargin  = 0.0;
   }

   // Sync history
   g_dashOnnxBull1  = g_histOnnxBull1;
   g_dashOnnxBear1  = g_histOnnxBear1;
   g_dashOnnxValid1 = g_histOnnxValid1;
   g_dashOnnxBull2  = g_histOnnxBull2;
   g_dashOnnxBear2  = g_histOnnxBear2;
   g_dashOnnxValid2 = g_histOnnxValid2;

   // Get live next trade decision
   GetNextTradeAction(g_dashNextAction);

   //--- Live position (reads only; no decision logic)
   g_dashHasOpenPosition = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         g_dashHasOpenPosition = true;
         g_dashPosType  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
         g_dashPosLots  = PositionGetDouble(POSITION_VOLUME);
         g_dashPosEntry = PositionGetDouble(POSITION_PRICE_OPEN);
         g_dashPosSL    = PositionGetDouble(POSITION_SL);
         g_dashPosTP    = PositionGetDouble(POSITION_TP);
         g_dashPosPL    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         break;
      }
   }

   //--- Today's tally + last block (owned by DecisionLog)
   g_dashTradesToday     = g_todayTrades;
   g_dashWinsToday       = g_todayWins;
   g_dashLossesToday     = g_todayLosses;
   g_dashNetPLToday      = g_todayNet;
   g_dashLastBlockSource = g_lastBlockSource;
   g_dashLastBlockReason = g_lastBlockReason;
}

//+------------------------------------------------------------------+
//| RenderGnnLines — 4 resistance + 4 support OBJ_HLINEs from the    |
//| GNN cache, drawn on the background z-plane so the opaque panel   |
//| stays on top. Labels (R1..R4 / S1..S4) are skipped when they'd   |
//| land under the panel (DashboardPointIsCovered).                  |
//+------------------------------------------------------------------+
void RenderGnnLines()
{
   for(int i = 0; i < 4; i++)
   {
      string uName = DB_PREFIX + "GNN_U" + IntegerToString(i);
      string lName = DB_PREFIX + "GNN_L" + IntegerToString(i);

      if(i < g_gnnUpperCount && g_gnnUpperLines[i] > 0.0)
      {
         if(ObjectFind(0, uName) < 0)
         {
            ObjectCreate(0, uName, OBJ_HLINE, 0, 0, g_gnnUpperLines[i]);
            ObjectSetInteger(0, uName, OBJPROP_COLOR, InpGnnUpperLineColor);
            ObjectSetInteger(0, uName, OBJPROP_WIDTH, InpGnnLineWidth);
            ObjectSetInteger(0, uName, OBJPROP_STYLE, STYLE_DOT);
            ObjectSetInteger(0, uName, OBJPROP_BACK, true);
            ObjectSetInteger(0, uName, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, uName, OBJPROP_HIDDEN, false);
         }
         else
            ObjectSetDouble(0, uName, OBJPROP_PRICE, g_gnnUpperLines[i]);
      }
      else if(ObjectFind(0, uName) >= 0)
         ObjectDelete(0, uName);

      if(i < g_gnnLowerCount && g_gnnLowerLines[i] > 0.0)
      {
         if(ObjectFind(0, lName) < 0)
         {
            ObjectCreate(0, lName, OBJ_HLINE, 0, 0, g_gnnLowerLines[i]);
            ObjectSetInteger(0, lName, OBJPROP_COLOR, InpGnnLowerLineColor);
            ObjectSetInteger(0, lName, OBJPROP_WIDTH, InpGnnLineWidth);
            ObjectSetInteger(0, lName, OBJPROP_STYLE, STYLE_DOT);
            ObjectSetInteger(0, lName, OBJPROP_BACK, true);
            ObjectSetInteger(0, lName, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, lName, OBJPROP_HIDDEN, false);
         }
         else
            ObjectSetDouble(0, lName, OBJPROP_PRICE, g_gnnLowerLines[i]);
      }
      else if(ObjectFind(0, lName) >= 0)
         ObjectDelete(0, lName);
   }

   //--- Labels (R1..R4 / S1..S4), suppressed under the panel
   if(InpShowGnnLineLabels)
   {
      datetime t = iTime(_Symbol, _Period, 0);
      for(int i = 0; i < g_gnnUpperCount; i++)
      {
         string lbl = DB_PREFIX + "GNN_LBL_U" + IntegerToString(i);
         int sx = 0, sy = 0;
         bool skip = false;
         if(t > 0 && ChartTimePriceToXY(0, 0, t, g_gnnUpperLines[i], sx, sy))
            skip = DashboardPointIsCovered(sx, sy);
         if(!skip)
         {
            if(ObjectFind(0, lbl) < 0)
            {
               ObjectCreate(0, lbl, OBJ_TEXT, 0, t, g_gnnUpperLines[i]);
               ObjectSetString(0, lbl, OBJPROP_FONT, "Consolas");
               ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 8);
               ObjectSetInteger(0, lbl, OBJPROP_COLOR, InpGnnUpperLineColor);
               ObjectSetInteger(0, lbl, OBJPROP_BACK, true);
               ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
               ObjectSetInteger(0, lbl, OBJPROP_HIDDEN, false);
            }
            ObjectSetString(0, lbl, OBJPROP_TEXT, "R" + IntegerToString(i + 1));
            ObjectSetInteger(0, lbl, OBJPROP_TIME, t);
            ObjectSetDouble(0, lbl, OBJPROP_PRICE, g_gnnUpperLines[i]);
         }
         else if(ObjectFind(0, lbl) >= 0)
            ObjectDelete(0, lbl);
      }
      for(int i = 0; i < g_gnnLowerCount; i++)
      {
         string lbl = DB_PREFIX + "GNN_LBL_L" + IntegerToString(i);
         int sx = 0, sy = 0;
         bool skip = false;
         if(t > 0 && ChartTimePriceToXY(0, 0, t, g_gnnLowerLines[i], sx, sy))
            skip = DashboardPointIsCovered(sx, sy);
         if(!skip)
         {
            if(ObjectFind(0, lbl) < 0)
            {
               ObjectCreate(0, lbl, OBJ_TEXT, 0, t, g_gnnLowerLines[i]);
               ObjectSetString(0, lbl, OBJPROP_FONT, "Consolas");
               ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 8);
               ObjectSetInteger(0, lbl, OBJPROP_COLOR, InpGnnLowerLineColor);
               ObjectSetInteger(0, lbl, OBJPROP_BACK, true);
               ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
               ObjectSetInteger(0, lbl, OBJPROP_HIDDEN, false);
            }
            ObjectSetString(0, lbl, OBJPROP_TEXT, "S" + IntegerToString(i + 1));
            ObjectSetInteger(0, lbl, OBJPROP_TIME, t);
            ObjectSetDouble(0, lbl, OBJPROP_PRICE, g_gnnLowerLines[i]);
         }
         else if(ObjectFind(0, lbl) >= 0)
            ObjectDelete(0, lbl);
      }
   }
   else
   {
      for(int i = 0; i < 4; i++)
      {
         if(ObjectFind(0, DB_PREFIX + "GNN_LBL_U" + IntegerToString(i)) >= 0)
            ObjectDelete(0, DB_PREFIX + "GNN_LBL_U" + IntegerToString(i));
         if(ObjectFind(0, DB_PREFIX + "GNN_LBL_L" + IntegerToString(i)) >= 0)
            ObjectDelete(0, DB_PREFIX + "GNN_LBL_L" + IntegerToString(i));
      }
   }
}

//+------------------------------------------------------------------+
//| Global helper: render ON/OFF state of a toggle                   |
//+------------------------------------------------------------------+
string ToggleState(bool value)
{
   return (value ? "[ON]  " : "[OFF] ");
}

//+------------------------------------------------------------------+
//| Settings summary — single source of truth for active config      |
//| Called once in OnInit; callable on demand for live audit.        |
//+------------------------------------------------------------------+
void PrintActiveConfiguration()
{
   Print("=============================================");
   Print("=== GoldEngine Sentinel — Active Configuration ===");
   Print("=============================================");
   Print("--- Core Engine & Structural ---");
   Print(ToggleState(InpUseOnnxCorePath),     "InpUseOnnxCorePath");
   Print(ToggleState(InpUseGnnReversion),     "InpUseGnnReversion");
   Print(ToggleState(InpUseDirectionalLock),  "InpUseDirectionalLock");
   Print(ToggleState(InpUseOppDirCooldown),   "InpUseOppDirCooldown");
   Print(ToggleState(InpUseConcurrencyCap),   "InpUseConcurrencyCap");
   Print(ToggleState(InpUsePriceZoneFilter),  "InpUsePriceZoneFilter");
   Print(ToggleState(InpUseGnnBoundaryBlock), "InpUseGnnBoundaryBlock");
   Print("--- AI-Discretionary Strategies ---");
   Print(ToggleState(InpUseMomentumConfirm),            "InpUseMomentumConfirm (N=" + IntegerToString(InpMomentumConsecutiveBars) + ", lean>" + DoubleToString(InpMomentumMinOnnxProb,2) + ", $" + DoubleToString(InpMomentumConfirmRiskUSD,0) + "/trade)");
   Print(ToggleState(InpUseStrategy_Pullback),          "InpUseStrategy_Pullback");
   Print(ToggleState(InpUseStrategy_Scalping),          "InpUseStrategy_Scalping");
   Print(ToggleState(InpUseStrategy_Straddle),          "InpUseStrategy_Straddle");
   Print(ToggleState(InpUseStrategy_Donchian),          "InpUseStrategy_Donchian");
   Print(ToggleState(InpUseStrategy_VolumeBreakout),    "InpUseStrategy_VolumeBreakout");
   Print(ToggleState(InpUseStrategy_VWAPPullback),      "InpUseStrategy_VWAPPullback");
   Print(ToggleState(InpUseStrategy_MeanReversion),     "InpUseStrategy_MeanReversion");
   Print(ToggleState(InpUseStrategy_Breakout),          "InpUseStrategy_Breakout");
   Print(ToggleState(InpUseStrategy_ExhaustionReentry), "InpUseStrategy_ExhaustionReentry");
   Print("--- Opinion-Based Gates ---");
   Print(ToggleState(InpUseDailyBiasVeto),        "InpUseDailyBiasVeto");
   Print(ToggleState(InpUseAIConvictionThreshold),"InpUseAIConvictionThreshold");
   Print(ToggleState(InpUseTrendConfluence),      "InpUseTrendConfluence");
   Print(ToggleState(InpUseADXRegimeLock),        "InpUseADXRegimeLock");
   Print(ToggleState(InpUseATRVolatilityFloor),   "InpUseATRVolatilityFloor");
   Print(ToggleState(InpUseOverExtensionGuard),   "InpUseOverExtensionGuard");
   Print("--- Step 4 Audit Additions ---");
   Print(ToggleState(InpUseGruAtrGate),           "InpUseGruAtrGate");
   Print(ToggleState(InpUseSessionHours),         "InpUseSessionHours");
   Print(ToggleState(InpUseADXGate),              "InpUseADXGate");
   Print(ToggleState(InpUseVolumeFilter),         "InpUseVolumeFilter");
   Print(ToggleState(InpUseEMAFilter),            "InpUseEMAFilter");
   Print(ToggleState(InpUseRSIFilter),            "InpUseRSIFilter");
   Print(ToggleState(InpUseMTFTrendFilter),       "InpUseMTFTrendFilter");
   Print(ToggleState(InpUseLocalDonchianBreakout),"InpUseLocalDonchianBreakout");
   Print(ToggleState(InpUseLocalVolBreakout),     "InpUseLocalVolBreakout");
   Print(ToggleState(InpUseLocalVWAPPullback),    "InpUseLocalVWAPPullback");
   Print("=== End Active Configuration ===");
}

//+------------------------------------------------------------------+
//| Expert initialization — print the full active configuration once |
//+------------------------------------------------------------------+
int OnInit()
{
   DecisionLogInit();
   OutcomeTrackerInit();
   g_gru76.Initialize(InpGruModelPath);
   UpdateOnnxCache();         // Run initial local prediction and swing caching immediately
   SyncDashboardState();
   DashboardInit();
   PrintActiveConfiguration();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DecisionLogDeinit();
   OutcomeTrackerDeinit();
   g_gru76.Release();
   DashboardDeinit();
}

//+------------------------------------------------------------------+
//| Trade events — cumulative SL/TP outcome ledger (record-only)     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      OutcomeTrackerOnDeal(trans.deal);
   }
}

//+------------------------------------------------------------------+
//| Chart events — forwards native object drag to the dashboard so   |
//| the moveable panel persists its position on drag-release.        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam,
                  const string &sparam)
{
   DashboardOnChartEvent(id, lparam, dparam, sparam);
}

//+------------------------------------------------------------------+
//| Expert tick — orchestration only; logic lives in the modules     |
//+------------------------------------------------------------------+
void OnTick()
{
   static datetime lastBarTime = 0;
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime != lastBarTime)
   {
      lastBarTime = barTime;
      UpdateOnnxCache();         // ONE cached ONNX source keyed on new-bar-open
      RefreshTodayStats();       // dashboard's "Today" tally (owned by DecisionLog)
      DispatchEnabledStrategies();
      CheckExitContract(g_cachedOnnxBull, g_cachedOnnxBear, g_cachedOnnxValid);
   }
   CheckExitContractTick();      // Evaluated on every tick to trail stop loss in real time
   UpdateLiveGnnBoundaries();    // Decoupled tick filter: re-evaluate raw swings against live price
   SyncDashboardState();
   RenderGnnLines();
   DashboardRefresh();
}