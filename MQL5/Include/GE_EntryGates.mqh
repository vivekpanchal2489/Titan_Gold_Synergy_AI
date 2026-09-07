//+------------------------------------------------------------------+
//| GE_EntryGates.mqh                                                |
//| Single source of truth for whether a trade is allowed to open.   |
//|                                                                  |
//| OWNED HERE (Step 2 + Step 4 structural list):                    |
//|   - ONNX permission check (directional agreement, fail-closed)   |
//|   - GNN Boundary Block                                           |
//|   - IsPriceInAllowedZone (InpUsePriceZoneFilter)                 |
//|   - Directional Lock (InpUseDirectionalLock)                     |
//|   - Opposite-Direction Cooldown (InpUseOppDirCooldown)           |
//|   - THE SINGLE ENTRY CHOKEPOINT: AttemptTradePlacement()         |
//|     (Step 2 + Step 7: logging + placement are inseparable here)  |
//|                                                                  |
//| ORDER (Step 2): ONNX check -> structural gates -> placement.     |
//| needsOnnxAgreement = (strategySource != ONNX_CORE &&             |
//|                       strategySource != GNN_REVERSION).          |
//|                                                                  |
//| GUARD RAILS:                                                     |
//|   - ONE cached ONNX source keyed on new-bar-open.                |
////|   - fail-closed: invalid inference blocks the trade.             |
//|   - No exit-price or sizing logic lives here.                    |
//|   - Every attempt, placed or blocked, goes through               |
//|     LogTradeAttempt() — no strategy can skip the log.            |
//+------------------------------------------------------------------+
#ifndef GE_ENTRYGATES_MQH
#define GE_ENTRYGATES_MQH

// One-directional dependency (Step 6 addendum):
//   GE_EntryGates.mqh may use GE_RiskManagement.mqh, GE_ExitContract.mqh
//   and GE_DecisionLog.mqh (used BY any module above it, never the reverse).
//   CTradeSafe (SL6/TP8-enforcing wrapper) comes from GE_ExitContract.mqh.
#include <GE_RiskManagement.mqh>
#include <GE_ExitContract.mqh>
#include <GE_DecisionLog.mqh>

//+------------------------------------------------------------------+
//| Kill Switch (EMERGENCY STOP)                                     |
//| true = block EVERY new trade immediately at the very top of       |
//| AttemptTradePlacement(), before the ONNX-agreement check, before  |
//| anything else. Deliberately does NOT close existing positions —   |
//| forced exits can slip worse than letting SL/TP/decay/reversal     |
//| resolve normally.                                                 |
//+------------------------------------------------------------------+
input group "=== Kill Switch ==="
input bool   InpKillSwitch        = false;   // EMERGENCY STOP — true = block all new trades immediately

//+------------------------------------------------------------------+
//| Structural Safety (Always Active)                                |
//+------------------------------------------------------------------+
input group "=== Structural Safety (Always Active) ==="
input bool   InpUseOnnxCorePath    = true;    // Require ONNX Core Path agreement before any entry
input bool   InpUseGnnReversion    = true;    // Enable GNN Reversion engine (independent of ONNX gate)
input bool   InpUseAntiAveragingDown=false;   // Prohibit 2nd trade in same direction if 1st is losing (false = allow AI sniper entries)
input bool   InpUseDirectionalLock = true;    // Block new positions opposite an existing one
input bool   InpUseOppDirCooldown  = false;   // Block re-entry in the same direction right after an opposite close (false = Instant V-Reversal Capture)
input bool   InpUsePriceZoneFilter = true;    // Only trade inside the permitted price zone
input bool   InpUseGnnBoundaryBlock= false;   // Block entries too close to the GNN ceiling/floor (false = Allow Full Breakout Trend Strikes)
input double InpBoundaryThreshold      = 0.50;  // Distance in USD from a GNN line considered safe to trade (Smart Calibration)
input int    InpOppDirCooldownSecs     = 60;    // Seconds to block same-direction re-entry after an opposite close

//+------------------------------------------------------------------+
//| ADX / ATR / Regime Thresholds                                    |
//+------------------------------------------------------------------+
input group "=== ADX/ATR/Regime Thresholds ==="
input double InpStructuralADXHardTrendLock = 35.0;  // ADX above which reversion trading is fully disabled (strong trend)
input double InpADXTrendGuard              = 25.0;  // ADX above this reversion is on hold (trend guard)
input double InpRegimeADXThreshold         = 25.0;  // ADX that separates trending vs. ranging market behavior
input double InpVolatilitySpikeRatio       = 1.4;   // How much current volatility must exceed average to flag a spike
input double InpMinATR                     = 0.50;  // Minimum ATR; below this volatility is too low to trade
input double InpGruAtrNormMin              = 0.00092; // Min normalized ATR for GRU-model trades
input double InpBreakoutVolMult            = 1.5;   // Volume vs average multiple that confirms a real breakout
input double InpBreakoutATRMult            = 1.5;   // ATR vs average multiple that confirms a real breakout
input int    InpRegimeVolSMAPeriod         = 20;    // Volume average window used for the spike check
input int    InpRegimeATRSMAPeriod         = 20;    // ATR average window used for the spike check
input double InpGnnTouchThreshold          = 0.20;  // Distance in USD that counts as "touching" a GNN line mid-candle
input double InpEmaProximityMarket         = 0.30;  // Distance in USD from the EMA required for a market entry
input double InpRSIOverboughtLevel         = 75.0;  // RSI level considered extreme blow-off overbought (allows healthy trends)
input double InpRSIOversoldLevel           = 25.0;  // RSI level considered extreme capitulation oversold (allows healthy trends)
input double InpOverExtensionDistanceUSD   = 1.50;  // Distance in USD from a key level considered "too far to chase"

//+------------------------------------------------------------------+
//| ONNX Core Conviction — the boss's own bar. These two inputs gate |
//| ONNX_CORE's OWN independent trades ONLY (its own entry engine).  |
//| Lowering either fires ONNX_CORE more often (looser bar); raising  |
//| either makes it fire less often but with a stronger edge per      |
//| trade (stricter bar). They do NOT gate the 9 AI-discretionary     |
//| strategies — those are direction-only (binary agreement) plus the |
//| optional InpStrategyOnnxMinProb lever below (default 0.0 = off).  |
//+------------------------------------------------------------------+
input group "=== ONNX Core Conviction (the boss's own bar) ==="
input double InpOnnxConfidence      = 0.52;   // Min ONNX probability required for its OWN independent trades (Default: 0.52)
input double InpOnnxMargin          = 0.10;   // Min probability gap (BULL vs BEAR) required for ONNX's own trades (Default: 0.10)
input double InpStrategyOnnxMinProb = 0.0;    // Optional: min ONNX probability required for AI-strategy entries too (0.0 = direction-only, no additional bar)

input group "=== Dynamic Session Conviction Scheduler (IST-based) ==="
input bool   InpUseDynamicScheduler = true;   // Enable dynamic conviction thresholds by time zone
input int    InpZone1StartHour      = 3;      // Zone 1 Start Hour (IST, default 3:30 AM)
input int    InpZone1StartMin       = 30;     // Zone 1 Start Minute (IST)
input double InpZone1Confidence     = 0.52;   // Zone 1 Confidence Threshold (Sydney/Tokyo Morning: 52%)
input double InpZone1Margin         = 0.10;   // Zone 1 Margin Gap

input int    InpZone2StartHour      = 13;     // Zone 2 Start Hour (IST, default 1:30 PM)
input int    InpZone2StartMin       = 30;     // Zone 2 Start Minute (IST)
input double InpZone2Confidence     = 0.50;   // Zone 2 Confidence Threshold (London/NY Peak: 50%)
input double InpZone2Margin         = 0.10;   // Zone 2 Margin Gap

input int    InpZone3StartHour      = 21;     // Zone 3 Start Hour (IST, default 9:30 PM)
input int    InpZone3StartMin       = 30;     // Zone 3 Start Minute (IST)
input double InpZone3Confidence     = 0.52;   // Zone 3 Confidence Threshold (Late NY Close: 52%)
input double InpZone3Margin         = 0.10;   // Zone 3 Margin Gap
input bool   InpUseEntryCurfew      = true;   // Block new entries during 2:00 AM to 3:30 AM IST
input int    InpCurfewStartHour     = 2;      // Curfew Start Hour (IST, 2 AM)
input int    InpCurfewStartMin      = 0;      // Curfew Start Min (IST)

//+------------------------------------------------------------------+
//| Format12Hour — convert hour/minute to 12h AM/PM string           |
//+------------------------------------------------------------------+
string Format12Hour(int hour, int min)
{
   string ampm = (hour >= 12) ? "PM" : "AM";
   int displayHour = hour % 12;
   if(displayHour == 0) displayHour = 12;
   return StringFormat("%02d:%02d %s", displayHour, min, ampm);
}

//+------------------------------------------------------------------+
//| IsCurfewActive — check if 2:00 AM to 3:30 AM IST curfew is active |
//+------------------------------------------------------------------+
bool IsCurfewActive()
{
   if(!InpUseDynamicScheduler) return false;
   MqlDateTime dt;
   GetISTDateTime(dt); // Universal IST clock
   int currentMinutes = dt.hour * 60 + dt.min;
   
   int cutoffMinutes = InpCurfewStartHour * 60 + InpCurfewStartMin; // 2:00 AM (120 min)
   int z1Minutes = InpZone1StartHour * 60 + InpZone1StartMin;       // 3:30 AM (210 min)
   
   if(currentMinutes >= cutoffMinutes && currentMinutes < z1Minutes)
      return true;
      
   return false;
}

//+------------------------------------------------------------------+
//| GetActiveConvictionSettings — dynamic session conviction finder  |
//+------------------------------------------------------------------+
void GetActiveConvictionSettings(double &activeConf, double &activeMargin, string &activeZoneName, string &activeZoneSched)
{
   if(!InpUseDynamicScheduler)
   {
      activeConf = InpOnnxConfidence;
      activeMargin = InpOnnxMargin;
      activeZoneName = "STATIC DEFAULT";
      activeZoneSched = StringFormat("Default: %.2f / %.2f", InpOnnxConfidence, InpOnnxMargin);
      return;
   }

   MqlDateTime dt;
   GetISTDateTime(dt); // Universal IST clock
   int currentMinutes = dt.hour * 60 + dt.min;
   
   int z1Minutes = InpZone1StartHour * 60 + InpZone1StartMin;
   int z2Minutes = InpZone2StartHour * 60 + InpZone2StartMin;
   int z3Minutes = InpZone3StartHour * 60 + InpZone3StartMin;

   // Zone 1: Sydney/Tokyo Open & Morning Chop (3:30 AM to 1:30 PM IST)
   if(currentMinutes >= z1Minutes && currentMinutes < z2Minutes)
   {
      activeConf = InpZone1Confidence;
      activeMargin = InpZone1Margin;
      activeZoneName = "SYDNEY/TOKYO";
      activeZoneSched = StringFormat("%s - %s (Strict: %.2f/%.2f)", 
                                     Format12Hour(InpZone1StartHour, InpZone1StartMin), 
                                     Format12Hour(InpZone2StartHour, InpZone2StartMin), 
                                     activeConf, activeMargin);
   }
   // Zone 2: London & NY Peak (1:30 PM to 9:30 PM IST)
   else if(currentMinutes >= z2Minutes && currentMinutes < z3Minutes)
   {
      activeConf = InpZone2Confidence;
      activeMargin = InpZone2Margin;
      activeZoneName = "LONDON/NY PEAK";
      activeZoneSched = StringFormat("%s - %s (Normal: %.2f/%.2f)", 
                                     Format12Hour(InpZone2StartHour, InpZone2StartMin), 
                                     Format12Hour(InpZone3StartHour, InpZone3StartMin), 
                                     activeConf, activeMargin);
   }
   // Zone 3: Late NY Close & Night Drift (9:30 PM to 3:30 AM IST)
   else
   {
      activeConf = InpZone3Confidence;
      activeMargin = InpZone3Margin;
      activeZoneName = "LATE NY DRIFT";
      activeZoneSched = StringFormat("%s - %s (U-Strict: %.2f/%.2f)", 
                                     Format12Hour(InpZone3StartHour, InpZone3StartMin), 
                                     Format12Hour(InpZone1StartHour, InpZone1StartMin), 
                                     activeConf, activeMargin);
   }
}

//+------------------------------------------------------------------+
//| Opinion-based entry gates (default FALSE)                        |
//+------------------------------------------------------------------+
input group "=== Opinion-Based Gates (default OFF) ==="
input bool   InpUseDailyBiasVeto       = false;  // Block trades that oppose the daily bias
input bool   InpUseAIConvictionThreshold = false; // Require AI conviction above a minimum to trade
input bool   InpUseTrendConfluence     = false;  // Require the tide/trend filter to agree with entry direction
input bool   InpUseADXRegimeLock       = false;  // Lock regime based on ADX before allowing entries
input bool   InpUseATRVolatilityFloor  = false;  // Require minimum ATR volatility before any entry
input bool   InpUseOverExtensionGuard  = false;  // Block chasing entries that are too extended from a key level

//+------------------------------------------------------------------+
//| Step 4 audit additions — entry-side filters (default FALSE)      |
//+------------------------------------------------------------------+
input group "=== Step 4 Audit Additions (default OFF) ==="
input bool   InpUseGruAtrGate          = false;  // GRU ATR-norm volatility gate
input bool   InpUseSessionHours        = false;  // Session momentum-hours gate
input bool   InpUseADXGate             = false;  // ADX trend gate in ONNX engine
input bool   InpUseVolumeFilter        = false;  // Volume filter (breakout confirm)
input bool   InpUseEMAFilter           = false;  // EMA trend filter
input int    InpEMAPeriod              = 50;     // Period of the EMA trend filter
input bool   InpUseRSIFilter           = true;   // Gate 8: RSI exhaustion filter (Blocks Buy @ Top >= 70, Blocks Sell @ Bottom <= 30)
input bool   InpUseCandleConfirm       = true;   // Gate 9: Candle color momentum confirmation (Wait-and-See)
input bool   InpUseMTFTrendFilter      = true;   // Gate 7b Multi-timeframe trend filter (H1 EMA 50)
input bool   InpUseInstitutionalSessions = false; // Gate 10a: Session Windows (false = 22 Hours / 5 Days Full Trading)
input bool   InpUseAsianRangeSweep     = true;   // Gate 10b: Asian Range High/Low Liquidity Sweep Detector
input bool   InpUseLocalDonchianBreakout = false; // Local Donchian breakout
input bool   InpUseLocalVolBreakout    = false;  // Local volume breakout
input bool   InpUseLocalVWAPPullback   = false;  // Local VWAP pullback


//+------------------------------------------------------------------+
//| Cached ONNX source (Step 2): ONE source keyed on new-bar-open.   |
//| Engine wiring arrives with GE_AIIntegration; until then the cache |
//| stays empty and every agreement-needing attempt is BLOCKED.      |
//+------------------------------------------------------------------+
datetime g_cachedOnnxBarTime = 0;
double   g_cachedOnnxBull    = 0.0;
double   g_cachedOnnxBear    = 0.0;
double   g_cachedOnnxMargin  = 0.0;
bool     g_cachedOnnxValid   = false;

// History of last 2 predictions (M5[-1] and M5[-2])
double   g_histOnnxBull1     = 0.0;
double   g_histOnnxBear1     = 0.0;
bool     g_histOnnxValid1    = false;
double   g_histOnnxBull2     = 0.0;
double   g_histOnnxBear2     = 0.0;
bool     g_histOnnxValid2    = false;

//+------------------------------------------------------------------+
//| Live regime/ADX cache — computed ONCE per new bar by the AI layer |
//| (RefreshRegimeCache below) and read by the dashboard. The         |
//| dashboard NEVER computes its own ADX/regime — it reads these.     |
//+------------------------------------------------------------------+
double g_cachedAdx    = 0.0;
double g_cachedAtr    = 0.0;
string g_cachedRegime = "SIDEWAYS";

void RefreshRegimeCache()
{
   double adxBuf[], atrBuf[];
   static int adxH = INVALID_HANDLE;
   if(adxH == INVALID_HANDLE) adxH = iADX(_Symbol, _Period, 14);
   static int atrH = INVALID_HANDLE;
   if(atrH == INVALID_HANDLE) atrH = iATR(_Symbol, _Period, 14);
   if(adxH != INVALID_HANDLE && CopyBuffer(adxH, 0, 0, 1, adxBuf) > 0)
      g_cachedAdx = adxBuf[0];
   if(atrH != INVALID_HANDLE && CopyBuffer(atrH, 0, 0, 1, atrBuf) > 0)
      g_cachedAtr = atrBuf[0];
   g_cachedRegime = (g_cachedAdx >= InpRegimeADXThreshold ? "TRENDING" : "SIDEWAYS");
}

//+------------------------------------------------------------------+
//| GNN boundary cache (Step 4) — owned here, populated by the AI/   |
//| ONNX layer before entry dispatch. GetGnnCeiling/GetGnnFloor read |
//| the cached lines; 0.0 means "no line available" (gate pass).     |
//+------------------------------------------------------------------+
double g_gnnCeiling = 0.0;
double g_gnnFloor   = 0.0;

//+------------------------------------------------------------------+
//| GNN structural lines (spec 09d Part 1): 4 resistance tiers above |
//| price + 4 support tiers below price. Populated by RefreshGNNCache |
//| (AI layer) once per bar; rendered by GE_Dashboard. Nearest-first  |
//| ordering (index 0 = closest to price). 0.0/count 0 = none.       |
//+------------------------------------------------------------------+
double g_gnnUpperLines[4] = {0.0, 0.0, 0.0, 0.0};
double g_gnnLowerLines[4] = {0.0, 0.0, 0.0, 0.0};
int    g_gnnUpperCount    = 0;
int    g_gnnLowerCount    = 0;

double g_rawGnnHighs[];
double g_rawGnnLows[];

double GetGnnCeiling() { return g_gnnCeiling; }
double GetGnnFloor()   { return g_gnnFloor;   }

//+------------------------------------------------------------------+
//| SAIEntryContext — the AI verdict fields the decision log records.|
//| Populated by GE_AIIntegration immediately before it calls the    |
//| chokepoint (aiActive=true when the AI engine responded with a    |
//| valid verdict; reason carries the AI's stated reason). If no AI  |
//| engine is wired, aiActive stays false and the log shows that the |
//| gate ran without AI input.                                       |
//+------------------------------------------------------------------+
struct SAIEntryContext
{
   bool   aiActive;
   int    conviction;
   string reason;
   string dailyBiasState;
};

SAIEntryContext g_aiEntryCtx;   // zero-init: aiActive=false, conviction=0

//+------------------------------------------------------------------+
//| DirectionToClass — single source of truth for mapping an entry    |
//| direction string ("BUY"/"SELL") to the ONNX predicted-class        |
//| vocabulary ("BULL"/"BEAR"). Both ONNX-agreement comparisons in     |
//| GATE 1 call this one helper; the mapping must never be duplicated  |
//| as two independent ternaries at different call sites.              |
//+------------------------------------------------------------------+
string DirectionToClass(const string direction)
{
   return (direction == "BUY") ? "BULL" : "BEAR";
}

//+------------------------------------------------------------------+
//| AttemptTradePlacement — THE SINGLE CHOKEPOINT (Step 2 + Step 7). |
//| Every strategy source funnels here; no strategy places anywhere  |
//| else. The Step 7 log row is written UNCONDITIONALLY (placed AND  |
//| blocked) inside this same function, so logging and placement are |
//| inseparable — a strategy cannot place without writing a row.     |
//|                                                                  |
//| needsOnnxAgreement = (strategySource != ONNX_CORE &&             |
//|                       strategySource != GNN_REVERSION).          |
//|                                                                  |
//| Returns true only when the order was actually sent.              |
//+------------------------------------------------------------------+
//| ShouldExecuteTrade — Multi-Filter Regime, ATR & Spread Guard     |
//+------------------------------------------------------------------+
bool ShouldExecuteTrade(double confidence, double slDistUSD)
{
   DetectMarketRegime();

   // 1. Regime filter: skip low-confidence noise in chop (< 0.50)
   if(g_currentMarketRegime == REGIME_CHOP && confidence < 0.50)
   {
      PrintFormat("[RegimeFilter VETO] Blocked: Chop regime + low confidence (%.2f < 0.50)", confidence);
      return false;
   }

   // 2. ATR filter: skip if ATR is dead flat (< 0.5x baseline)
   static int atrH14 = INVALID_HANDLE;
   static int atrH100 = INVALID_HANDLE;
   if(atrH14 == INVALID_HANDLE) atrH14 = iATR(_Symbol, PERIOD_M5, 14);
   if(atrH100 == INVALID_HANDLE) atrH100 = iATR(_Symbol, PERIOD_M5, 100);
   
   double a14Buf[1], a100Buf[1];
   if(atrH14 != INVALID_HANDLE && atrH100 != INVALID_HANDLE)
   {
      if(CopyBuffer(atrH14, 0, 0, 1, a14Buf) > 0 && CopyBuffer(atrH100, 0, 0, 1, a100Buf) > 0)
      {
         if(a100Buf[0] > 0.0 && a14Buf[0] < a100Buf[0] * 0.50)
         {
            PrintFormat("[ATRFilter VETO] Blocked: Volatility dead flat (ATR14 %.2f < 0.5x ATR100 %.2f)", a14Buf[0], a100Buf[0]);
            return false;
         }
      }
   }

   // 3. Spread filter: skip if spread is too wide (> 35 points / 3.5 pips)
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > 35)
   {
      PrintFormat("[SpreadFilter VETO] Blocked: Spread too wide (%d points > 35 max)", spread);
      return false;
   }

//+------------------------------------------------------------------+
//| GetAsianSessionRange — Computes Asian Session High & Low (00-06) |
//+------------------------------------------------------------------+
void GetAsianSessionRange(double &asianHigh, double &asianLow)
{
   asianHigh = 0.0;
   asianLow  = 0.0;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime todayStart = StructToTime(dt);
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_M5, 0, 150, rates);
   if(copied <= 0) return;
   
   double hi = 0.0;
   double lo = 999999.0;
   int count = 0;
   
   for(int i = 0; i < copied; i++)
   {
      if(rates[i].time >= todayStart)
      {
         MqlDateTime bdt;
         TimeToStruct(rates[i].time, bdt);
         if(bdt.hour >= 0 && bdt.hour < 6)
         {
            if(rates[i].high > hi) hi = rates[i].high;
            if(rates[i].low < lo) lo = rates[i].low;
            count++;
         }
      }
   }
   
   if(count > 0 && hi > 0.0 && lo < 999999.0)
   {
      asianHigh = hi;
      asianLow  = lo;
   }
}

//+------------------------------------------------------------------+
//| AttemptTradePlacement — Unified funnel for ALL trade placements   |
//+------------------------------------------------------------------+
bool AttemptTradePlacement(const string strategySource, const string direction)
{
   //=== KILL SWITCH (THE VERY FIRST CHECK — before ONNX agreement,
   //=== before anything else). true blocks EVERY new trade instantly.
   if(InpKillSwitch || g_killSwitchBtnActive)
   {
      g_lastBlockSource = strategySource;
      g_lastBlockReason = "KILL_SWITCH_ACTIVE";
      SDecisionRecord ksRec;
      ksRec.timestamp        = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
      ksRec.symbol           = _Symbol;
      ksRec.direction        = direction;
      ksRec.strategy_source  = strategySource;
      ksRec.result           = "BLOCKED";
      ksRec.block_reason     = "KILL_SWITCH_ACTIVE";
      LogTradeAttempt(ksRec);
      return false;
   }

   //=== ENTRY CURFEW CHECK (1:00 AM to 3:30 AM IST)
   if(InpUseEntryCurfew && IsCurfewActive())
   {
      g_lastBlockSource = strategySource;
      g_lastBlockReason = "ENTRY_CURFEW";
      SDecisionRecord cfRec;
      cfRec.timestamp        = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
      cfRec.symbol           = _Symbol;
      cfRec.direction        = direction;
      cfRec.strategy_source  = strategySource;
      cfRec.result           = "BLOCKED";
      cfRec.block_reason     = "ENTRY_CURFEW";
      LogTradeAttempt(cfRec);
      return false;
   }

   //=== HIGH IMPACT NEWS FILTER CHECK (MT5 Native Economic Calendar)
   string newsEvent = "";
   if(InpUseNewsFilter && IsHighImpactNewsActive(newsEvent))
   {
      g_lastBlockSource = strategySource;
      g_lastBlockReason = "NEWS_FILTER";
      SDecisionRecord newsRec;
      newsRec.timestamp        = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
      newsRec.symbol           = _Symbol;
      newsRec.direction        = direction;
      newsRec.strategy_source  = strategySource;
      newsRec.result           = "BLOCKED";
      newsRec.block_reason     = "NEWS_FILTER";
      newsRec.ai_reason_text   = StringFormat("High-Impact USD News: %s", newsEvent);
      LogTradeAttempt(newsRec);
      return false;
   }

   SDecisionRecord rec;
   rec.timestamp       = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
   rec.symbol          = _Symbol;
   rec.direction       = direction;
   rec.strategy_source = strategySource;

   // MOMENTUM_CONFIRM and GNN_REVERSION have their own autonomous entry authority
   bool needsOnnxAgreement = (strategySource != "ONNX_CORE" && strategySource != "GNN_REVERSION" && strategySource != "MOMENTUM_CONFIRM");
   if(g_cachedOnnxValid)
   {
      rec.onnx_prob_bull      = g_cachedOnnxBull;
      rec.onnx_prob_bear      = g_cachedOnnxBear;
      rec.onnx_margin         = MathAbs(g_cachedOnnxBull - g_cachedOnnxBear);
      rec.onnx_predicted_class = (g_cachedOnnxBull > g_cachedOnnxBear ? "BULL" : "BEAR");
   }
   else
   {
      rec.onnx_prob_bull      = 0.0;
      rec.onnx_prob_bear      = 0.0;
      rec.onnx_margin         = 0.0;
      rec.onnx_predicted_class = "N/A";
   }

   //--- ADX / ATR / regime (real market reads)
   double adxBuf[], atrBuf[];
   static int adxH = INVALID_HANDLE;
   if(adxH == INVALID_HANDLE) adxH = iADX(_Symbol, _Period, 14);
   static int atrH = INVALID_HANDLE;
   if(atrH == INVALID_HANDLE) atrH = iATR(_Symbol, _Period, 14);
   if(adxH != INVALID_HANDLE && CopyBuffer(adxH, 0, 0, 1, adxBuf) > 0)
      rec.adx_value = adxBuf[0];
   if(atrH != INVALID_HANDLE && CopyBuffer(atrH, 0, 0, 1, atrBuf) > 0)
      rec.atr_value = atrBuf[0];
   rec.regime_mode = (rec.adx_value >= InpRegimeADXThreshold ? "TRENDING" : "SIDEWAYS");

   //--- AI fields (populated by GE_AIIntegration via g_aiEntryCtx before this call)
   rec.ai_active       = g_aiEntryCtx.aiActive;
   rec.ai_conviction   = g_aiEntryCtx.conviction;
   rec.ai_reason_text  = g_aiEntryCtx.reason;
   rec.daily_bias_state = g_aiEntryCtx.dailyBiasState;

   //=== GATE 1: ONNX directional permission (fail-closed) ===
   // needsOnnxAgreement = source != ONNX_CORE && source != GNN_REVERSION.
   //   - GNN_REVERSION is exempt: it is its own direction engine.
   //   - ONNX_CORE's direction IS the model read; it still requires a
   //     valid cache and the confidence/margin thresholds below.
   if(needsOnnxAgreement)
   {
      // Fail-closed: absent/invalid cache blocks every agreement-needing source.
      if(!g_cachedOnnxValid)
      {
         rec.result          = "BLOCKED";
         rec.block_reason    = "ONNX_DISAGREE";
         rec.ai_reason_text  = "ONNX cache invalid, fail-closed";
         LogTradeAttempt(rec);
         return false;
      }
      // (a) Directional agreement: the strategy's requested direction must
      //     match the model's predicted class — a BINARY check (Step 2
      //     design). InpOnnxConfidence/InpOnnxMargin do NOT factor in here;
      //     they gate ONNX_CORE's own trades only.
      // (b) InpStrategyOnnxMinProb (default 0.0 = OFF): when set > 0, the
      //     strategy must ALSO clear max(P_BULL, P_BEAR) >= the bar. This is
      //     the optional lever to tighten AI-strategy entries later without
      //     a code change. 0.0 preserves direction-only behavior exactly.
      string predicted = (g_cachedOnnxBull > g_cachedOnnxBear ? "BULL" : "BEAR");
      double maxProb   = MathMax(g_cachedOnnxBull, g_cachedOnnxBear);
      if(DirectionToClass(direction) != predicted ||
         (InpStrategyOnnxMinProb > 0.0 && maxProb < InpStrategyOnnxMinProb))
      {
         rec.result          = "BLOCKED";
         rec.block_reason    = "ONNX_DISAGREE";
         rec.ai_reason_text  = "ONNX directional agreement not met";
         LogTradeAttempt(rec);
         return false;
      }
   }
   else if(strategySource == "ONNX_CORE")
   {
      // ONNX_CORE: the model IS the direction source — valid cache and
      // confidence/margin thresholds are still mandatory (fail-closed).
      if(!g_cachedOnnxValid)
      {
         rec.result          = "BLOCKED";
         rec.block_reason    = "ONNX_DISAGREE";
         rec.ai_reason_text  = "ONNX cache invalid, fail-closed";
         LogTradeAttempt(rec);
         return false;
      }
      string predicted = (g_cachedOnnxBull > g_cachedOnnxBear ? "BULL" : "BEAR");
      double dirProb   = (direction == "BUY" ? g_cachedOnnxBull : g_cachedOnnxBear);
      double margin    = MathAbs(g_cachedOnnxBull - g_cachedOnnxBear);
      double activeConf = InpOnnxConfidence;
      double activeMargin = InpOnnxMargin;
      string activeZoneName = "";
      string activeZoneSched = "";
      GetActiveConvictionSettings(activeConf, activeMargin, activeZoneName, activeZoneSched);

      if(DirectionToClass(direction) != predicted || dirProb < activeConf || margin < activeMargin)
      {
         rec.result          = "BLOCKED";
         rec.block_reason    = "ONNX_DISAGREE";
         rec.ai_reason_text  = StringFormat("ONNX core conviction/margin not met (Active threshold: %.2f/%.2f)", activeConf, activeMargin);
         LogTradeAttempt(rec);
         return false;
      }
   }
   else if(strategySource == "MOMENTUM_CONFIRM")
   {
      // MOMENTUM_CONFIRM: price-streak entry with a LOW-conviction ONNX lean.
      // Does NOT use the 0.70/0.20 core bar — only directional agreement at the
      // reduced lean threshold (InpMomentumMinOnnxProb, default 0.50). The
      // price-streak check is done in the dispatcher before this call.
      // Fail-closed: absent cache blocks momentum entirely.
      if(!g_cachedOnnxValid)
      {
         rec.result          = "BLOCKED";
         rec.block_reason    = "ONNX_DISAGREE";
         rec.ai_reason_text  = "ONNX cache invalid, fail-closed";
         LogTradeAttempt(rec);
         return false;
      }
      string predicted = (g_cachedOnnxBull > g_cachedOnnxBear ? "BULL" : "BEAR");
      double dirProb   = (direction == "BUY" ? g_cachedOnnxBull : g_cachedOnnxBear);
      if(DirectionToClass(direction) != predicted || dirProb < InpMomentumMinOnnxProb)
      {
         rec.result          = "BLOCKED";
         rec.block_reason    = "ONNX_DISAGREE";
         rec.ai_reason_text  = "Momentum ONNX lean not met";
         LogTradeAttempt(rec);
         return false;
      }
   }
   // GNN_REVERSION: no ONNX agreement required (its own engine decides).
   // The trade is still recorded with the ONNX read for the log row.

   //=== GATE 2: Concurrency cap ===
   if(InpUseConcurrencyCap)
   {
      int openCount = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0) continue;
         if(StringCompare(PositionGetString(POSITION_SYMBOL), _Symbol, false) != 0) continue;
         if(InpManageOnlyMagicNumber && InpMagicNumber > 0 && PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
         openCount++;
      }
      if(openCount >= InpMaxConcurrentTrades)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "CONCURRENCY_CAP";
         rec.ai_reason_text = StringFormat("Max concurrent trades reached (%d/%d)", openCount, InpMaxConcurrentTrades);
         LogTradeAttempt(rec);
         return false;
      }
   }

   //=== GATE 2b: Anti-Averaging-Down & Same-Direction Cap ===
   int sameDirCount = 0;
   bool hasLosingSameDirPosition = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0 || StringCompare(PositionGetString(POSITION_SYMBOL), _Symbol, false) != 0)
         continue;
      if(InpManageOnlyMagicNumber && InpMagicNumber > 0 && PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      string posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
      if(posDir == direction)
      {
         sameDirCount++;
         double posProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(posProfit < 0.0)
            hasLosingSameDirPosition = true;
      }
   }

   if(InpUseAntiAveragingDown && hasLosingSameDirPosition)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "ANTI_AVERAGING_DOWN";
      rec.ai_reason_text = "Existing position in this direction is currently in drawdown - No averaging down permitted!";
      LogTradeAttempt(rec);
      return false;
   }

   if(InpMaxPositionsPerDir > 0 && sameDirCount >= InpMaxPositionsPerDir)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "SAME_DIR_CAP";
      rec.ai_reason_text = StringFormat("Max %s positions reached (%d/%d)", direction, sameDirCount, InpMaxPositionsPerDir);
      LogTradeAttempt(rec);
      return false;
   }

   //=== GATE 3: Directional lock ===
   if(InpUseDirectionalLock)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0 || StringCompare(PositionGetString(POSITION_SYMBOL), _Symbol, false) != 0)
            continue;
         if(InpManageOnlyMagicNumber && InpMagicNumber > 0 && PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
         string posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
         if(posDir != direction)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "DIRECTIONAL_LOCK";
            rec.ai_reason_text = StringFormat("Directional lock active - existing position is %s", posDir);
            LogTradeAttempt(rec);
            return false;
         }
      }
   }

   //=== GATE 3b: Two-Strike Directional Loss Circuit Breaker ===
   // If 2 consecutive losses occurred in the same direction, pause that direction for 30 minutes
   HistorySelect(TimeCurrent() - 3600, TimeCurrent());
   int dealTotal = HistoryDealsTotal();
   int consecDirLosses = 0;
   datetime lastDealTime = 0;
   for(int d = dealTotal - 1; d >= 0; d--)
   {
      ulong deal = HistoryDealGetTicket(d);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if(InpManageOnlyMagicNumber && InpMagicNumber > 0 && HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      
      double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT);
      long dType = HistoryDealGetInteger(deal, DEAL_TYPE);
      string closedDir = (dType == DEAL_TYPE_BUY ? "SELL" : "BUY"); // Closing a BUY deal is DEAL_TYPE_SELL, closing a SELL deal is DEAL_TYPE_BUY
      
      if(closedDir == direction)
      {
         if(pnl < 0.0)
         {
            if(consecDirLosses == 0) lastDealTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
            consecDirLosses++;
         }
         else if(pnl > 0.35)
         {
            break;
         }
      }
      else
      {
         break;
      }
   }

   if(consecDirLosses >= 2 && lastDealTime > 0 && (TimeCurrent() - lastDealTime) < 1800) // 30 min cooldown
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "TWO_STRIKE_PAUSE";
      int minsLeft = (int)((1800 - (TimeCurrent() - lastDealTime)) / 60);
      rec.ai_reason_text = StringFormat("2 consecutive %s losses - %d min cooling pause active to prevent fighting trend", direction, minsLeft);
      LogTradeAttempt(rec);
      return false;
   }

   //=== GATE 4: Opposite-direction cooldown (Step 4) ===
   // Blocks re-entry in the same direction right after an opposite close.
   // Scans the trade history: if the most recent opposite-direction close
   // happened within InpOppDirCooldownSecs, this same-direction re-entry is
   // blocked (the EA would otherwise re-enter instantly after a reversal).
   if(InpUseOppDirCooldown)
   {
      datetime lastOppClose = 0;
      HistorySelect(0, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int d = total - 1; d >= 0; d--)
      {
         ulong deal = HistoryDealGetTicket(d);
         if(deal == 0)
            continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
            continue;
         if(InpManageOnlyMagicNumber && InpMagicNumber > 0 && HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
            continue;
         if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
            continue;
         long dealType = HistoryDealGetInteger(deal, DEAL_TYPE);
         string closedDir = (dealType == DEAL_TYPE_BUY ? "BUY" : "SELL");
         // Opposite of the attempted direction means the position closed
         // was the opposite one (e.g. attempted BUY after a SELL closed).
         if(closedDir == direction)
         {
            lastOppClose = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
            break;
         }
      }
      if(lastOppClose > 0 && (TimeCurrent() - lastOppClose) < InpOppDirCooldownSecs)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "OPP_DIR_COOLDOWN";
         int secsLeft = (int)(InpOppDirCooldownSecs - (TimeCurrent() - lastOppClose));
         rec.ai_reason_text = StringFormat("Opposite direction cooldown active (%d seconds remaining)", secsLeft);
         LogTradeAttempt(rec);
         return false;
      }
   }

   //=== GATE 5: Price zone filter ===
   if(InpUsePriceZoneFilter)
   {
      double price = (direction == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                        : SymbolInfoDouble(_Symbol, SYMBOL_BID));
      double lo = iLow(_Symbol, PERIOD_D1, 0);
      double hi = iHigh(_Symbol, PERIOD_D1, 0);
      if(price < lo || price > hi)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "PRICE_ZONE";
         rec.ai_reason_text = StringFormat("Price %.2f outside Daily Zone (Lo: %.2f, Hi: %.2f)", price, lo, hi);
         LogTradeAttempt(rec);
         return false;
      }
   }

   //=== GATE 6: GNN boundary block (Step 4) ===
   // Blocks entries too close to the opposite GNN line (BUY under the
   // Golden Ceiling, SELL above the Aqua Floor). Reads the GNN lines that
   // the AI/ONNX layer computes and publishes before entry dispatch.
   if(InpUseGnnBoundaryBlock)
   {
      double price = (direction == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                        : SymbolInfoDouble(_Symbol, SYMBOL_BID));
      double ceiling = GetGnnCeiling();
      double floor   = GetGnnFloor();
      if(ceiling > 0.0 && direction == "BUY" && (ceiling - price) < InpBoundaryThreshold)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "GNN_BOUNDARY";
         rec.ai_reason_text = StringFormat("BUY price %.2f too close to Golden Ceiling %.2f (< $%.2f buffer)", price, ceiling, InpBoundaryThreshold);
         LogTradeAttempt(rec);
         return false;
      }
      if(floor > 0.0 && direction == "SELL" && (price - floor) < InpBoundaryThreshold)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "GNN_BOUNDARY";
         rec.ai_reason_text = StringFormat("SELL price %.2f too close to Aqua Floor %.2f (< $%.2f buffer)", price, floor, InpBoundaryThreshold);
         LogTradeAttempt(rec);
         return false;
      }
   }

   //=== GATE 7: EMA Trend Filter ===
   if(InpUseEMAFilter)
   {
      static int emaH = INVALID_HANDLE;
      if(emaH == INVALID_HANDLE) emaH = iMA(_Symbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(emaH != INVALID_HANDLE)
      {
         double emaBuf[1];
         if(CopyBuffer(emaH, 0, 0, 1, emaBuf) > 0)
         {
            double emaVal = emaBuf[0];
            double price = (direction == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                              : SymbolInfoDouble(_Symbol, SYMBOL_BID));
            if(direction == "BUY" && price < emaVal)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "EMA_TREND_FILTER";
               rec.ai_reason_text = StringFormat("Price %.2f below EMA %d (%.2f)", price, InpEMAPeriod, emaVal);
               LogTradeAttempt(rec);
               return false;
            }
            if(direction == "SELL" && price > emaVal)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "EMA_TREND_FILTER";
               rec.ai_reason_text = StringFormat("Price %.2f above EMA %d (%.2f)", price, InpEMAPeriod, emaVal);
               LogTradeAttempt(rec);
               return false;
            }
         }
      }
   }

   //=== GATE 7b: Absolute Macro Trend Hierarchy (H1 EMA 50) ===
   if(InpUseMTFTrendFilter)
   {
      static int mtfEmaH = INVALID_HANDLE;
      if(mtfEmaH == INVALID_HANDLE) mtfEmaH = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
      if(mtfEmaH != INVALID_HANDLE)
      {
         double mtfEmaBuf[1];
         if(CopyBuffer(mtfEmaH, 0, 0, 1, mtfEmaBuf) > 0)
         {
            double mtfEmaVal = mtfEmaBuf[0];
            double price = (direction == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                              : SymbolInfoDouble(_Symbol, SYMBOL_BID));
            if(direction == "BUY" && price < mtfEmaVal)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "MACRO_BEAR_TREND";
               rec.ai_reason_text = StringFormat("Price %.2f is below H1 EMA 50 (%.2f) - Macro Trend is BEARISH, BUYs strictly prohibited", price, mtfEmaVal);
               LogTradeAttempt(rec);
               return false;
            }
            if(direction == "SELL" && price > mtfEmaVal)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "MACRO_BULL_TREND";
               rec.ai_reason_text = StringFormat("Price %.2f is above H1 EMA 50 (%.2f) - Macro Trend is BULLISH, SELLs strictly prohibited", price, mtfEmaVal);
               LogTradeAttempt(rec);
               return false;
            }
         }
      }
   }

   //=== GATE 8: RSI Exhaustion Filter ===
   if(InpUseRSIFilter)
   {
      static int rsiH = INVALID_HANDLE;
      if(rsiH == INVALID_HANDLE) rsiH = iRSI(_Symbol, _Period, 14, PRICE_CLOSE);
      if(rsiH != INVALID_HANDLE)
      {
         double rsiBuf[1];
         if(CopyBuffer(rsiH, 0, 0, 1, rsiBuf) > 0)
         {
            double rsiVal = rsiBuf[0];
            if(direction == "BUY" && rsiVal >= InpRSIOverboughtLevel)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "RSI_EXHAUSTION";
               rec.ai_reason_text = StringFormat("RSI %.2f >= Overbought level %.1f", rsiVal, InpRSIOverboughtLevel);
               LogTradeAttempt(rec);
               return false;
            }
            if(direction == "SELL" && rsiVal <= InpRSIOversoldLevel)
            {
               rec.result       = "BLOCKED";
               rec.block_reason = "RSI_EXHAUSTION";
               rec.ai_reason_text = StringFormat("RSI %.2f <= Oversold level %.1f", rsiVal, InpRSIOversoldLevel);
               LogTradeAttempt(rec);
               return false;
            }
         }
      }
   }

   //=== GATE 9: Smart Candle Color Confirmation & Anti-Falling-Knife Physics Guard ===
   if(InpUseCandleConfirm)
   {
      double open1  = iOpen(_Symbol, _Period, 1);
      double close1 = iClose(_Symbol, _Period, 1);
      double low1   = iLow(_Symbol, _Period, 1);
      double high1  = iHigh(_Symbol, _Period, 1);
      double lastBarRange = high1 - low1;

      static int ema20H = INVALID_HANDLE;
      if(ema20H == INVALID_HANDLE)
         ema20H = iMA(_Symbol, _Period, 20, 0, MODE_EMA, PRICE_CLOSE);
         
      double emaVal = 0.0;
      if(ema20H != INVALID_HANDLE)
      {
         double buf[1];
         if(CopyBuffer(ema20H, 0, 1, 1, buf) > 0) emaVal = buf[0];
      }

      static int atrH = INVALID_HANDLE;
      if(atrH == INVALID_HANDLE)
         atrH = iATR(_Symbol, _Period, 14);
      double atrNow = 2.0;
      if(atrH != INVALID_HANDLE)
      {
         double aBuf[1];
         if(CopyBuffer(atrH, 0, 1, 1, aBuf) > 0 && aBuf[0] > 0.0) atrNow = aBuf[0];
      }

      double currentAIProb = MathMax(g_cachedOnnxBull, g_cachedOnnxBear);
      bool isHighConviction = (g_cachedOnnxValid && currentAIProb >= 0.58 && g_cachedOnnxMargin >= 0.10);

      // 0. Directional Volatility Shock & News Explosion Veto:
      // Only block if the shock moved AGAINST the trade direction (e.g. violent red dump against BUY or green rocket against SELL)
      // A strong green bounce on 70%+ Bull AI is buying absorption, NOT a shock against us!
      double shockLimit = MathMax(3.0 * atrNow, 25.0);
      if(atrNow > 0.0 && lastBarRange >= shockLimit)
      {
         if(direction == "BUY" && close1 <= open1)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "VOLATILITY_SHOCK";
            rec.ai_reason_text = StringFormat("Violent Red Dump ($%.2f >= $%.2f) - Waiting for Green stabilization bar", lastBarRange, shockLimit);
            LogTradeAttempt(rec);
            return false;
         }
         if(direction == "SELL" && close1 >= open1)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "VOLATILITY_SHOCK";
            rec.ai_reason_text = StringFormat("Violent Green Pump ($%.2f >= $%.2f) - Waiting for Red stabilization bar", lastBarRange, shockLimit);
            LogTradeAttempt(rec);
            return false;
         }
      }

      // 1. Anti-Chasing Value Location Guard:
      // Never buy when price is stretched > 2.5x ATR above M5 EMA 20 or after 3 consecutive green bars.
      // Never sell when price is stretched > 2.5x ATR below M5 EMA 20 or after 3 consecutive red bars.
      double maxExtension = MathMax(2.5 * atrNow, 6.0);

      int greenStreak = 0;
      for(int s = 1; s <= 5; s++)
      {
         if(iClose(_Symbol, _Period, s) > iOpen(_Symbol, _Period, s)) greenStreak++;
         else break;
      }

      int redStreak = 0;
      for(int s = 1; s <= 5; s++)
      {
         if(iClose(_Symbol, _Period, s) < iOpen(_Symbol, _Period, s)) redStreak++;
         else break;
      }

      if(direction == "BUY")
      {
         if(emaVal > 0.0 && (close1 - emaVal) > maxExtension)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "OVEREXTENSION_CHASE";
            rec.ai_reason_text = StringFormat("Price %.2f stretched +$%.2f above EMA 20 (%.2f) > Limit %.2f - Waiting for pullback to Fair Value", 
                                              close1, (close1 - emaVal), emaVal, maxExtension);
            LogTradeAttempt(rec);
            return false;
         }
         if(greenStreak >= 3 && close1 > open1)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "PARABOLIC_CHASE";
            rec.ai_reason_text = StringFormat("Parabolic Surge (%d green bars in a row) - Waiting for 1-bar pullback before buying", greenStreak);
            LogTradeAttempt(rec);
            return false;
         }
      }

      if(direction == "SELL")
      {
         if(emaVal > 0.0 && (emaVal - close1) > maxExtension)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "OVEREXTENSION_CHASE";
            rec.ai_reason_text = StringFormat("Price %.2f stretched -$%.2f below EMA 20 (%.2f) > Limit %.2f - Waiting for rally pullback to Fair Value", 
                                              close1, (emaVal - close1), emaVal, maxExtension);
            LogTradeAttempt(rec);
            return false;
         }
         if(redStreak >= 3 && close1 < open1)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "WATERFALL_CHASE";
            rec.ai_reason_text = StringFormat("Waterfall Dump (%d red bars in a row) - Waiting for 1-bar pullback before selling", redStreak);
            LogTradeAttempt(rec);
            return false;
         }
      }

      // 2. Anti-Falling-Knife & Waterfall Liquidation Veto (PHYSICS RULE — NO BYPASS):
      // Even on 99% AI conviction, NEVER BUY into an active red waterfall candle!
      // The market MUST print at least ONE Green stabilization bar (or 40% hammer bounce) before BUYing.
      if(direction == "BUY" && (redStreak >= 2 || close1 <= open1))
      {
         double lowerWick = MathMin(open1, close1) - low1;
         double candleRange = high1 - low1;
         bool isHammerBounce = (candleRange > 0.0 && (lowerWick / candleRange) >= 0.40 && close1 > low1 + 0.40 * candleRange);

         if(!isHammerBounce)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "FALLING_KNIFE";
            rec.ai_reason_text = StringFormat("Market dumping in %d-candle red cascade (Last: %.2f <= %.2f) - Waiting for Green stabilization bar", 
                                              redStreak, close1, open1);
            LogTradeAttempt(rec);
            return false;
         }
      }

      if(direction == "SELL" && (greenStreak >= 2 || close1 >= open1))
      {
         double upperWick = high1 - MathMax(open1, close1);
         double candleRange = high1 - low1;
         bool isShootingStar = (candleRange > 0.0 && (upperWick / candleRange) >= 0.40 && close1 < high1 - 0.40 * candleRange);

         if(!isShootingStar)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "RISING_SURGE";
            rec.ai_reason_text = StringFormat("Market surging in %d-candle green pump (Last: %.2f >= %.2f) - Waiting for Red stabilization bar", 
                                              greenStreak, close1, open1);
            LogTradeAttempt(rec);
            return false;
         }
      }
   }

   //=== GATE 10: Regime, Low ATR & Spread Execution Guard ===
   double activeConviction = MathMax(g_cachedOnnxBull, g_cachedOnnxBear);
   if(!ShouldExecuteTrade(activeConviction, 6.0))
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "REGIME_EXEC_FILTER";
      rec.ai_reason_text = "Blocked by Regime Chop/ATR/Spread Execution Gate";
      LogTradeAttempt(rec);
      return false;
   }

   //=== GATE 10a: Institutional High-Liquidity Session Windows ===
   if(InpUseInstitutionalSessions)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int timeMins = dt.hour * 60 + dt.min;
      
      // London Expansion Window: 07:00 to 11:30 UTC (420 to 690 mins)
      // New York Open & Overlap Window: 12:30 to 17:30 UTC (750 to 1050 mins)
      bool isLondonWindow = (timeMins >= 420 && timeMins <= 690);
      bool isNewYorkWindow = (timeMins >= 750 && timeMins <= 1050);
      
      // High AI Conviction (>= 75%) can trade during London/NY afternoon extension up to 19:00 (1140 mins)
      bool isLateExtension = (timeMins > 1050 && timeMins <= 1140 && activeConviction >= 0.75);
      
      if(!isLondonWindow && !isNewYorkWindow && !isLateExtension)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "SESSION_LOW_LIQUIDITY";
         rec.ai_reason_text = StringFormat("Time %02d:%02d outside Institutional High-Liquidity Windows (London 07:00-11:30, NY 12:30-17:30) - Asian/Late chop blocked", dt.hour, dt.min);
         LogTradeAttempt(rec);
         return false;
      }
   }

   //=== GATE 10b: Asian Range High/Low Liquidity Sweep Guard ===
   if(InpUseAsianRangeSweep)
   {
      double asianHigh = 0.0, asianLow = 0.0;
      GetAsianSessionRange(asianHigh, asianLow);
      
      if(asianHigh > 0.0 && asianLow > 0.0)
      {
         double curPrice = (direction == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
         
         // If price is extended > $6 above Asian High, do not chase BUY (wait for pullback or short sweep)
         if(direction == "BUY" && (curPrice - asianHigh) > 6.0 && activeConviction < 0.75)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "ASIAN_HIGH_OVEREXTENSION";
            rec.ai_reason_text = StringFormat("Price %.2f is +$%.2f above Asian High (%.2f) - High risk of reversal sweep", curPrice, (curPrice - asianHigh), asianHigh);
            LogTradeAttempt(rec);
            return false;
         }
         // If price is extended > $6 below Asian Low, do not chase SELL
         if(direction == "SELL" && (asianLow - curPrice) > 6.0 && activeConviction < 0.75)
         {
            rec.result       = "BLOCKED";
            rec.block_reason = "ASIAN_LOW_OVEREXTENSION";
            rec.ai_reason_text = StringFormat("Price %.2f is -$%.2f below Asian Low (%.2f) - High risk of bounce sweep", curPrice, (asianLow - curPrice), asianLow);
            LogTradeAttempt(rec);
            return false;
         }
      }
   }

//=== Placement: lot size, SL/TP via CTradeSafe (the SL6/TP8 wrapper) ===
   // VALIDATED contract: SL = InpATRMultiplier x ATR(14) (SL6), TP = SL x
   // InpFomoRRRatio (TP8) — ATR-based exits.
   double atrBufVal[];
   double atrNow = 2.0;
   static int atrHNow = INVALID_HANDLE;
   if(atrHNow == INVALID_HANDLE)
      atrHNow = iATR(_Symbol, _Period, 14);
   if(atrHNow != INVALID_HANDLE && CopyBuffer(atrHNow, 0, 0, 1, atrBufVal) > 0 && atrBufVal[0] > 0.0)
      atrNow = atrBufVal[0];
   bool useATR = (InpUseATRStopLoss && atrNow > 0.0);

   // 1. SL/TP price distances: ATR contract + Hunt-Proof Structural Swing Extreme Buffer.
   double slDistUSD = (useATR ? (InpATRMultiplier * atrNow) : 6.0);

   // Hunt-Proof Structural Stop Loss: Anchor SL outside the lowest/highest wick of the last 8 bars!
   if(direction == "BUY")
   {
      double lowestLow8 = iLow(_Symbol, _Period, 1);
      for(int b = 2; b <= 8; b++)
      {
         double bLow = iLow(_Symbol, _Period, b);
         if(bLow < lowestLow8) lowestLow8 = bLow;
      }
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double structuralDist = (ask - lowestLow8) + InpLiquidityBufferUSD;
      if(structuralDist > slDistUSD)
         slDistUSD = structuralDist;
   }
   else // SELL
   {
      double highestHigh8 = iHigh(_Symbol, _Period, 1);
      for(int b = 2; b <= 8; b++)
      {
         double bHigh = iHigh(_Symbol, _Period, b);
         if(bHigh > highestHigh8) highestHigh8 = bHigh;
      }
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double structuralDist = (highestHigh8 - bid) + InpLiquidityBufferUSD;
      if(structuralDist > slDistUSD)
         slDistUSD = structuralDist;
   }

   // Safety bounds on SL distance: Min $4.50 (Breathable Floor), Max $18.00 (Wide Volatility Breathing Room)
   if(slDistUSD < 4.50) slDistUSD = 4.50;
   if(slDistUSD > 18.00) slDistUSD = 18.00;

   // 2. Conviction & Trade Execution Filter
   double activeConf = InpOnnxConfidence;
   double activeMargin = InpOnnxMargin;
   string activeZoneName = "";
   string activeZoneSched = "";
   GetActiveConvictionSettings(activeConf, activeMargin, activeZoneName, activeZoneSched);

   double tradeConf = (g_cachedOnnxValid ? ((direction == "BUY") ? g_cachedOnnxBull : g_cachedOnnxBear) : activeConf);
   if(!ShouldExecuteTrade(tradeConf, slDistUSD))
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "REGIME_FILTER_VETO";
      LogTradeAttempt(rec);
      return false;
   }

   // 3. Regime-Adjusted Half-Kelly Lot Sizing
   double lot = 0.01;
   if(strategySource == "MOMENTUM_CONFIRM")
   {
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickValue <= 0.0)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "RISK_CAP_UNHONORED";
         LogTradeAttempt(rec);
         return false;
      }
      double lossPerLot = (InpExitSLDistUSD / tickSize) * tickValue;
      lot = InpMomentumConfirmRiskUSD / lossPerLot;
      if(lot <= 0.0)
      {
         rec.result       = "BLOCKED";
         rec.block_reason = "RISK_CAP_UNHONORED";
         LogTradeAttempt(rec);
         return false;
      }
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(lotStep > 0.0)
         lot = MathFloor(lot / lotStep) * lotStep;
      double brokerMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(lot < brokerMin) lot = brokerMin;
   }
   else
   {
      lot = CalculateLotSizeWithConfidence(slDistUSD, strategySource, direction, tradeConf, activeConf);
   }

   if(lot <= 0.0)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "RISK_CAP_UNHONORED";
      LogTradeAttempt(rec);
      return false;
   }

   double tpDistUSD = useATR ? (slDistUSD * InpFomoRRRatio) : InpExitTPDistUSD;
   if(slDistUSD <= 0.0 || tpDistUSD <= 0.0)
   {
      rec.result       = "BLOCKED";
      rec.block_reason = "RISK_CAP_UNHONORED";
      LogTradeAttempt(rec);
      return false;
   }

   double price = (direction == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                      : SymbolInfoDouble(_Symbol, SYMBOL_BID));
   double sl    = (direction == "BUY" ? price - slDistUSD : price + slDistUSD);
   double tp    = (direction == "BUY" ? price + tpDistUSD : price - tpDistUSD);

   CTradeSafe trade;               // SL6/TP8 enforced inside the wrapper
   bool ok = (direction == "BUY" ? trade.BuySafe(lot, _Symbol, slDistUSD, tpDistUSD)
                                  : trade.SellSafe(lot, _Symbol, slDistUSD, tpDistUSD));

   rec.result      = (ok ? "PLACED" : "BLOCKED");
   rec.block_reason = (ok ? "NONE" : "ORDER_REJECTED");
   if(ok)
   {
      rec.entry_price = price;
      rec.sl_price    = sl;
      rec.tp_price    = tp;
      rec.lot_size    = lot;
      rec.risk_usd    = (useATR ? (slDistUSD * lot * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) / SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE)) : InpFixedRiskUSD);
   }
   LogTradeAttempt(rec);
   return ok;
}

//+------------------------------------------------------------------+
//| GetNextTradeAction — compute planned next action for dashboard   |
//+------------------------------------------------------------------+
void GetNextTradeAction(string &nextAction)
{
   if(InpKillSwitch || g_killSwitchBtnActive)
   {
      nextAction = "BLOCKED: Kill Switch Active";
      return;
   }
   if(InpUseEntryCurfew && IsCurfewActive())
   {
      nextAction = "BLOCKED: Entry Curfew Active (until 3:30 AM IST)";
      return;
   }
   string activeNewsEvent = "";
   if(InpUseNewsFilter && IsHighImpactNewsActive(activeNewsEvent))
   {
      nextAction = StringFormat("PAUSED: High-Impact News (%s)", activeNewsEvent);
      return;
   }
   if(!g_cachedOnnxValid)
   {
      nextAction = "INITIALIZING: ONNX Cache Pending";
      return;
   }
   
   // Check Concurrency Cap
   int openCount = 0;
   int sameDirCount = 0;
   bool hasLosingSameDirPosition = false;
   string openPosDir = "";
   string dir = (g_cachedOnnxBull > g_cachedOnnxBear ? "BUY" : "SELL");
   double dirProb = (dir == "BUY" ? g_cachedOnnxBull : g_cachedOnnxBear);
   double margin = MathAbs(g_cachedOnnxBull - g_cachedOnnxBear);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(StringCompare(PositionGetString(POSITION_SYMBOL), _Symbol, false) != 0) continue;
      if(InpManageOnlyMagicNumber && InpMagicNumber > 0 && PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      openCount++;
      string pDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");
      openPosDir = pDir;
      if(pDir == dir)
      {
         sameDirCount++;
         double posProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(posProfit < 0.0) hasLosingSameDirPosition = true;
      }
   }

   if(InpUseConcurrencyCap && openCount >= InpMaxConcurrentTrades)
   {
      nextAction = StringFormat("PAUSED: Max Concurrency (%d/%d Trades)", openCount, InpMaxConcurrentTrades);
      return;
   }
   
   if(InpMaxPositionsPerDir > 0 && sameDirCount >= InpMaxPositionsPerDir)
   {
      nextAction = StringFormat("PAUSED: Max %s Open (%d/%d)", dir, sameDirCount, InpMaxPositionsPerDir);
      return;
   }

   if(InpUseAntiAveragingDown && hasLosingSameDirPosition)
   {
      nextAction = StringFormat("PAUSED: Anti-Averaging (%s in Drawdown)", dir);
      return;
   }

   if(InpUseDirectionalLock && openCount > 0 && openPosDir != dir)
   {
      nextAction = StringFormat("PAUSED: Direction Lock (Holding %s)", openPosDir);
      return;
   }

   // Check Opposite Direction Cooldown
   if(InpUseOppDirCooldown)
   {
      datetime lastOppClose = 0;
      HistorySelect(0, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int d = total - 1; d >= 0; d--)
      {
         ulong deal = HistoryDealGetTicket(d);
         if(deal == 0) continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
         if(InpManageOnlyMagicNumber && InpMagicNumber > 0 && HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber) continue;
         if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         long dealType = HistoryDealGetInteger(deal, DEAL_TYPE);
         string closedDir = (dealType == DEAL_TYPE_BUY ? "BUY" : "SELL");
         if(closedDir == dir)
         {
            lastOppClose = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
            break;
         }
      }
      if(lastOppClose > 0 && (TimeCurrent() - lastOppClose) < InpOppDirCooldownSecs)
      {
         int secsLeft = (int)(InpOppDirCooldownSecs - (TimeCurrent() - lastOppClose));
         nextAction = StringFormat("PAUSED: Opposite Cooldown (%ds left)", secsLeft);
         return;
      }
   }
   
   // Check ONNX Core thresholds
   double activeConf = InpOnnxConfidence;
   double activeMargin = InpOnnxMargin;
   string activeZoneName = "";
   string activeZoneSched = "";
   GetActiveConvictionSettings(activeConf, activeMargin, activeZoneName, activeZoneSched);

   if(dirProb < activeConf || margin < activeMargin)
   {
      nextAction = StringFormat("WAITING: %s Conf %.1f%% < %.1f%%", dir, dirProb * 100.0, activeConf * 100.0);
      return;
   }

   // Check GNN Boundary Block
   if(InpUseGnnBoundaryBlock)
   {
      double price = (dir == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
      double ceiling = GetGnnCeiling();
      double floor   = GetGnnFloor();
      if(ceiling > 0.0 && dir == "BUY" && (ceiling - price) < InpBoundaryThreshold)
      {
         nextAction = StringFormat("PAUSED: Near Golden Ceiling %.2f (< $%.2f)", ceiling, InpBoundaryThreshold);
         return;
      }
      if(floor > 0.0 && dir == "SELL" && (price - floor) < InpBoundaryThreshold)
      {
         nextAction = StringFormat("PAUSED: Near Aqua Floor %.2f (< $%.2f)", floor, InpBoundaryThreshold);
         return;
      }
   }

   // Check MTF Trend Filter (H1 EMA 50)
   bool isHighConvictionAlpha = (g_cachedOnnxValid && dirProb >= 0.68 && margin >= 0.20);
   if(InpUseMTFTrendFilter && !isHighConvictionAlpha)
   {
      static int mtfEmaH = INVALID_HANDLE;
      if(mtfEmaH == INVALID_HANDLE) mtfEmaH = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
      if(mtfEmaH != INVALID_HANDLE)
      {
         double mtfEmaBuf[1];
         if(CopyBuffer(mtfEmaH, 0, 0, 1, mtfEmaBuf) > 0)
         {
            double mtfEmaVal = mtfEmaBuf[0];
            double price = (dir == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
            if(dir == "BUY" && price < mtfEmaVal)
            {
               nextAction = StringFormat("PAUSED: Price %.2f < H1 EMA50 (%.2f)", price, mtfEmaVal);
               return;
            }
            if(dir == "SELL" && price > mtfEmaVal)
            {
               nextAction = StringFormat("PAUSED: Price %.2f > H1 EMA50 (%.2f)", price, mtfEmaVal);
               return;
            }
         }
      }
   }
   
   // Check EMA filter if enabled
   if(InpUseEMAFilter)
   {
      static int emaH = INVALID_HANDLE;
      if(emaH == INVALID_HANDLE) emaH = iMA(_Symbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(emaH != INVALID_HANDLE)
      {
         double emaBuf[1];
         if(CopyBuffer(emaH, 0, 0, 1, emaBuf) > 0)
         {
            double emaVal = emaBuf[0];
            double price = (dir == "BUY" ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID));
            if(dir == "BUY" && price < emaVal)
            {
               nextAction = StringFormat("PAUSED: Price %.2f < EMA %d (%.2f)", price, InpEMAPeriod, emaVal);
               return;
            }
            else if(dir == "SELL" && price > emaVal)
            {
               nextAction = StringFormat("PAUSED: Price %.2f > EMA %d (%.2f)", price, InpEMAPeriod, emaVal);
               return;
            }
         }
      }
   }

   // Check RSI filter if enabled
   if(InpUseRSIFilter)
   {
      double rsi = g_cachedRsi;
      if(dir == "BUY" && rsi >= InpRSIOverboughtLevel)
      {
         nextAction = StringFormat("PAUSED: RSI Overbought (%.1f)", rsi);
         return;
      }
      else if(dir == "SELL" && rsi <= InpRSIOversoldLevel)
      {
         nextAction = StringFormat("PAUSED: RSI Oversold (%.1f)", rsi);
         return;
      }
   }

   // Check Anti-Chasing Overextension & Candle Color Confirmation if enabled
   if(InpUseCandleConfirm)
   {
      double close1 = iClose(_Symbol, _Period, 1);
      double open1  = iOpen(_Symbol, _Period, 1);

      static int ema20H = INVALID_HANDLE;
      if(ema20H == INVALID_HANDLE) ema20H = iMA(_Symbol, _Period, 20, 0, MODE_EMA, PRICE_CLOSE);
      double emaVal = 0.0;
      if(ema20H != INVALID_HANDLE)
      {
         double buf[1];
         if(CopyBuffer(ema20H, 0, 1, 1, buf) > 0) emaVal = buf[0];
      }

      static int atrH = INVALID_HANDLE;
      if(atrH == INVALID_HANDLE) atrH = iATR(_Symbol, _Period, 14);
      double atrNow = 2.0;
      if(atrH != INVALID_HANDLE)
      {
         double aBuf[1];
         if(CopyBuffer(atrH, 0, 1, 1, aBuf) > 0 && aBuf[0] > 0.0) atrNow = aBuf[0];
      }

      double high1 = iHigh(_Symbol, _Period, 1);
      double low1  = iLow(_Symbol, _Period, 1);
      double lastBarRange = high1 - low1;

      double shockLimit = MathMax(3.0 * atrNow, 25.0);
      if(atrNow > 0.0 && lastBarRange >= shockLimit)
      {
         if(dir == "BUY" && close1 <= open1)
         {
            nextAction = StringFormat("PAUSED: Volatility Dump ($%.2f >= $%.2f)", lastBarRange, shockLimit);
            return;
         }
         if(dir == "SELL" && close1 >= open1)
         {
            nextAction = StringFormat("PAUSED: Volatility Pump ($%.2f >= $%.2f)", lastBarRange, shockLimit);
            return;
         }
      }

      if(emaVal > 0.0 && atrNow > 0.0)
      {
         double maxExtension = 2.5 * atrNow;
         if(maxExtension < 5.0) maxExtension = 5.0;
         if(dir == "BUY" && (close1 - emaVal) > maxExtension)
         {
            nextAction = StringFormat("PAUSED: Overextended +$%.2f > Limit %.2f", (close1 - emaVal), maxExtension);
            return;
         }
         if(dir == "SELL" && (emaVal - close1) > maxExtension)
         {
            nextAction = StringFormat("PAUSED: Overextended -$%.2f > Limit %.2f", (emaVal - close1), maxExtension);
            return;
         }
      }

      if(open1 > 0.0 && close1 > 0.0)
      {
         if(dir == "BUY" && close1 <= open1)
         {
            nextAction = "PAUSED: Falling Knife (Waiting for Green M5)";
            return;
         }
         else if(dir == "SELL" && close1 >= open1)
         {
            nextAction = "PAUSED: Rising Surge (Waiting for Red M5)";
            return;
         }
      }
   }
   
   nextAction = StringFormat("ARMED: %s (%.1f%% Conf | Margin +%.3f)", dir, dirProb * 100.0, margin);
}

#endif // GE_ENTRYGATES_MQH