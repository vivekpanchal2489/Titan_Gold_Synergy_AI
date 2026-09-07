//+------------------------------------------------------------------+
//| Titan_Sentinel_Frozen_V1_Test.mq5                                |
//| Dedicated Test Engine for Frozen V1 Release                      |
//| Copyright 2026, Quantitative Institutional Gold Trading System   |
//+------------------------------------------------------------------+
#property copyright "Titan Gold Sentinel — Frozen V1 Test Edition"
#property version   "1.00"
#property description "Dedicated Standalone Test EA for Frozen V1 Architecture"
#property strict

#include <GE_RiskManagement.mqh>
#include <GE_ExitContract.mqh>
#include <GE_EntryGates.mqh>
#include <GE_AIIntegration.mqh>
#include <GE_DecisionLog.mqh>
#include <GE_OutcomeTracker.mqh>
#include <GE_Dashboard.mqh>

input group "=== Frozen V1 Test Controls ==="
input ulong InpTestMagicNumber = 777888; // Unique Test Magic Number

void SyncDashboardState()
{
   g_dashKillSwitchActive = (InpKillSwitch || g_killSwitchBtnActive);
   g_dashCurfewActive     = (InpUseEntryCurfew && IsCurfewActive());
   g_dashRegimeMode       = g_cachedRegime;
   g_dashADX              = g_cachedAdx;
   g_dashATR              = g_cachedAtr;
   g_cachedRsi            = DashRSI(0);

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

   g_dashOnnxBull1  = g_histOnnxBull1;
   g_dashOnnxBear1  = g_histOnnxBear1;
   g_dashOnnxValid1 = g_histOnnxValid1;
   g_dashOnnxBull2  = g_histOnnxBull2;
   g_dashOnnxBear2  = g_histOnnxBear2;
   g_dashOnnxValid2 = g_histOnnxValid2;

   GetNextTradeAction(g_dashNextAction);

   g_dashHasOpenPosition = false;
   g_dashOpenPosCount    = 0;
   g_dashPosLots         = 0.0;
   g_dashPosPL           = 0.0;
   string lastType       = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && StringCompare(PositionGetString(POSITION_SYMBOL), _Symbol, false) == 0)
      {
         g_dashHasOpenPosition = true;
         g_dashOpenPosCount++;
         lastType       = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
         g_dashPosLots += PositionGetDouble(POSITION_VOLUME);
         g_dashPosEntry = PositionGetDouble(POSITION_PRICE_OPEN);
         g_dashPosSL    = PositionGetDouble(POSITION_SL);
         g_dashPosTP    = PositionGetDouble(POSITION_TP);
         g_dashPosPL   += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
   g_dashPosType = lastType;

   g_dashTradesToday     = g_todayTrades;
   g_dashWinsToday       = g_todayWins;
   g_dashLossesToday     = g_todayLosses;
   g_dashNetPLToday      = g_todayNet;
   g_dashLastAttemptTime   = g_lastAttemptTime;
   g_dashLastAttemptResult = g_lastAttemptResult;
   g_dashLastBlockSource   = g_lastBlockSource;
   g_dashLastBlockReason   = g_lastBlockReason;
   g_dashLastBlockDetail   = g_lastBlockDetail;
}

int OnInit()
{
   DecisionLogInit();
   OutcomeTrackerInit();
   if(InpUseAdvancedModel)
   {
      g_gruAdvanced.Init(InpAdvancedModelPath);
   }
   else
   {
      g_gru76.Initialize(InpGruModelPath);
   }
   UpdateOnnxCache();
   SyncDashboardState();
   DashboardInit();
   EventSetTimer(1);
   Print("==================================================");
   Print("TITAN SENTINEL FROZEN V1 TEST EA INITIALIZED");
   Print("Magic Number: ", InpTestMagicNumber);
   Print("==================================================");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DecisionLogDeinit();
   OutcomeTrackerDeinit();
   if(!InpUseAdvancedModel)
   {
      g_gru76.Release();
   }
   DashboardDeinit();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      OutcomeTrackerOnDeal(trans.deal);
   }
}

void OnChartEvent(const int id, const long &lparam, const double &dparam,
                  const string &sparam)
{
   DashboardOnChartEvent(id, lparam, dparam, sparam);
}

void OnTimer()
{
   CheckExitContractTick();
   RefreshTodayStats();
   SyncDashboardState();
   DashboardRefresh();
}

void OnTick()
{
   static datetime lastBarTime = 0;
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(lastBarTime == 0)
   {
      lastBarTime = barTime;
      UpdateOnnxCache();
      SyncDashboardState();
      return;
   }
   if(barTime != lastBarTime)
   {
      lastBarTime = barTime;
      UpdateOnnxCache();
      DispatchEnabledStrategies();
      CheckExitContract(g_cachedOnnxBull, g_cachedOnnxBear, g_cachedOnnxValid);
   }
   CheckExitContractTick();
   UpdateLiveGnnBoundaries();
   RefreshTodayStats();
   SyncDashboardState();
   DashboardRefresh();
}
