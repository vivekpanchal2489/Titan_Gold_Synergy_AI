//+------------------------------------------------------------------+
//|                                           GoldAI_Master_V1.mq5   |
//|               Institutional Self-Learning Gold AI Trading Bot    |
//|                    High-Precision Machine Learning Execution     |
//+------------------------------------------------------------------+
#property copyright "Gold AI Institutional Quant"
#property link      "https://github.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include "..\Include\GoldAI_Features.mqh"
#include "..\Include\GoldAI_ONNXEngine.mqh"

//--- Inputs
input group "=== AI Inference Settings ==="
input string   InpModelFileName        = "gold_master_ai.onnx"; // ONNX Model File (in MQL5/Files)
input double   InpMinConfidence        = 0.68;                  // Minimum AI Probability Threshold (0.68 = 68%)
input bool     InpTradeOnNewBarOnly    = true;                  // Trade Only On Candle Close

input group "=== Institutional Risk Management ==="
input double   InpFixedLotSize         = 0.05;                  // Fixed Trade Volume (Lots)
input double   InpRiskPercent          = 1.0;                   // Dynamic Risk % Per Trade (if AutoLot=true)
input bool     InpUseDynamicLot        = false;                 // Enable Dynamic Risk Sizing
input double   InpAtrMultiplierTP      = 1.5;                   // Take Profit ATR Multiplier (1.5x)
input double   InpAtrMultiplierSL      = 1.0;                   // Stop Loss ATR Multiplier (1.0x)
input double   InpMaxSpreadPoints      = 35.0;                  // Max Spread Protection (in Points)
input double   InpMaxDailyLossPercent  = 4.0;                   // Daily Loss Circuit Breaker (%)

input group "=== Trade Protection & Trailing ==="
input bool     InpUseBreakEven         = true;                  // Move SL to Break-Even at 1.0x ATR
input bool     InpUseCandleTrailing    = true;                  // Trail SL by Previous Candle Extremes
input ulong    InpMagicNumber          = 999888;                // EA Magic Number

//--- Global Objects
CTrade            g_trade;
CGoldAIFeatures   g_features;
CGoldAIONNXEngine g_onnx;

datetime          g_lastBarTime;
double            g_startingDailyEquity;
datetime          g_currentDay;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetMarginMode();
   g_trade.SetTypeFillingBySymbol(_Symbol);
   
   g_lastBarTime = 0;
   g_startingDailyEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_currentDay = TimeCurrent() / 86400;
   
   Print("==========================================================");
   Print("Initializing Gold AI Institutional Master EA...");
   Print("==========================================================");
   
   if(!g_features.Initialize(_Symbol, (ENUM_TIMEFRAMES)_Period))
   {
      Print("[GoldAI] ERROR: Failed to initialize Feature Engine.");
      return INIT_FAILED;
   }
   
   if(!g_onnx.Initialize(InpModelFileName))
   {
      PrintFormat("[GoldAI] WARNING: Could not find '%s' in MQL5/Files. Please place the trained ONNX model in MQL5/Files.", InpModelFileName);
   }
   
   Print("✓ Gold AI Master EA Initialized Successfully.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   g_features.Release();
   g_onnx.Release();
   Comment("");
}

//+------------------------------------------------------------------+
//| Check Daily Drawdown Circuit Breaker                             |
//+------------------------------------------------------------------+
bool IsDailyLossBreakerHit()
{
   datetime today = TimeCurrent() / 86400;
   if(today != g_currentDay)
   {
      g_currentDay = today;
      g_startingDailyEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
   
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = ((g_startingDailyEquity - currentEquity) / g_startingDailyEquity) * 100.0;
   
   if(lossPercent >= InpMaxDailyLossPercent)
   {
      Comment(StringFormat("⚠ DAILY LOSS CIRCUIT BREAKER HIT: %.2f%% Loss. Trading Suspended for today.", lossPercent));
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Manage Open Positions (Break-Even & Candle Trailing)             |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      
      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      CopyRates(_Symbol, _Period, 1, 2, rates);
      
      // 1. Break-Even Check
      if(InpUseBreakEven)
      {
         if(posType == POSITION_TYPE_BUY && currentPrice > (openPrice + (openPrice - currentSL)))
         {
            if(currentSL < openPrice)
            {
               g_trade.PositionModify(ticket, openPrice + (_Point * 10), currentTP);
               PrintFormat("[GoldAI] BUY Trade #%d moved to Break-Even.", ticket);
            }
         }
         else if(posType == POSITION_TYPE_SELL && currentPrice < (openPrice - (currentSL - openPrice)))
         {
            if(currentSL > openPrice)
            {
               g_trade.PositionModify(ticket, openPrice - (_Point * 10), currentTP);
               PrintFormat("[GoldAI] SELL Trade #%d moved to Break-Even.", ticket);
            }
         }
      }
      
      // 2. Candle Trailing Stop Check
      if(InpUseCandleTrailing && ArraySize(rates) >= 2)
      {
         if(posType == POSITION_TYPE_BUY)
         {
            double newSL = rates[1].low - (_Point * 10);
            if(newSL > currentSL && newSL < currentPrice)
            {
               g_trade.PositionModify(ticket, newSL, currentTP);
            }
         }
         else if(posType == POSITION_TYPE_SELL)
         {
            double newSL = rates[1].high + (_Point * 10);
            if((newSL < currentSL || currentSL == 0) && newSL > currentPrice)
            {
               g_trade.PositionModify(ticket, newSL, currentTP);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistancePrice)
{
   if(!InpUseDynamicLot || slDistancePrice <= 0)
      return InpFixedLotSize;
      
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (InpRiskPercent / 100.0);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   if(tickSize <= 0 || tickValue <= 0) return InpFixedLotSize;
   
   double ticksAtRisk = slDistancePrice / tickSize;
   double lot = riskAmount / (ticksAtRisk * tickValue);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lot = MathFloor(lot / step) * step;
   return MathMax(minLot, MathMin(maxLot, lot));
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ManageOpenTrades();
   
   if(IsDailyLossBreakerHit()) return;
   
   // Spread Protection Filter
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spread > InpMaxSpreadPoints)
   {
      Comment(StringFormat("Spread too high: %.1f points (Max allowed: %.1f)", spread, InpMaxSpreadPoints));
      return;
   }
   
   // Check New Bar
   datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(InpTradeOnNewBarOnly && currentBarTime == g_lastBarTime)
   {
      return;
   }
   g_lastBarTime = currentBarTime;
   
   // Extract 42 Institutional Features
   float features[];
   if(!g_features.ExtractFeatures(features))
   {
      Print("[GoldAI] Failed to extract feature vector.");
      return;
   }
   
   // Run ONNX Prediction
   SModelPrediction pred;
   if(!g_onnx.Predict(features, pred))
   {
      Comment("Gold AI: ONNX Model offline. Awaiting model file in MQL5/Files...");
      return;
   }
   
   // Display Live HUD
   string hud = StringFormat("=== GOLD AI INSTITUTIONAL SNIPER ===\n" +
                             "Model: %s\n" +
                             "Probability Bullish (TP): %.2f%%\n" +
                             "Probability Neutral (Chop): %.2f%%\n" +
                             "Probability Bearish (TP): %.2f%%\n" +
                             "Confidence Filter: %.0f%%\n" +
                             "Active Signal: %s\n" +
                             "Spread: %.1f pts",
                             InpModelFileName,
                             pred.probBullish * 100.0,
                             pred.probNeutral * 100.0,
                             pred.probBearish * 100.0,
                             InpMinConfidence * 100.0,
                             (pred.predictedClass == 0) ? "BULLISH 🟢" : ((pred.predictedClass == 2) ? "BEARISH 🔴" : "NEUTRAL ⚪"),
                             spread);
   Comment(hud);
   
   // Check if existing open trade
   if(PositionsTotal() > 0) return;
   
   // Get ATR for Dynamic SL/TP
   double atrBuf[1];
   int hAtr = iATR(_Symbol, _Period, 14);
   CopyBuffer(hAtr, 0, 0, 1, atrBuf);
   IndicatorRelease(hAtr);
   double currentAtr = (atrBuf[0] > 0) ? atrBuf[0] : (2.50); // default $2.50 gold atr
   
   double tpDist = InpAtrMultiplierTP * currentAtr;
   double slDist = InpAtrMultiplierSL * currentAtr;
   
   // High-Confidence Sniper Execution Gate
   if(pred.predictedClass == 0 && pred.probBullish >= InpMinConfidence)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = ask - slDist;
      double tp = ask + tpDist;
      double lots = CalculateLotSize(slDist);
      
      PrintFormat("[GoldAI] >>> EXECUTING HIGH-CONFIDENCE BUY <<< (Confidence: %.2f%%)", pred.probBullish * 100.0);
      g_trade.Buy(lots, _Symbol, ask, sl, tp, "GoldAI Sniper BUY");
   }
   else if(pred.predictedClass == 2 && pred.probBearish >= InpMinConfidence)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = bid + slDist;
      double tp = bid - tpDist;
      double lots = CalculateLotSize(slDist);
      
      PrintFormat("[GoldAI] >>> EXECUTING HIGH-CONFIDENCE SELL <<< (Confidence: %.2f%%)", pred.probBearish * 100.0);
      g_trade.Sell(lots, _Symbol, bid, sl, tp, "GoldAI Sniper SELL");
   }
}
