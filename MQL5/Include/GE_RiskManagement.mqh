//+------------------------------------------------------------------+
//| GE_RiskManagement.mqh                                            |
//| Single source of truth: "how much, and how many at once."        |
//|                                                                  |
//| OWNED HERE (nothing about direction or exit price):              |
//|   - Lot sizing formula                                           |
//|   - Per-trade USD risk cap (always enforced, whatever value)     |
//|   - Streak multipliers                                           |
//|   - Concurrency cap enforcement (InpUseConcurrencyCap)           |
//|   - Dynamic confidence-based risk scaling                        |
//|                                                                  |
//| GUARD RAILS:                                                     |
//|   - No entry direction logic, no SL/TP price logic lives here.   |
//|   - The cap is always enforced regardless of the input value;    |
//|     these inputs only change the NUMBER, not the enforcement.    |
//|   - Lot calculation is locked at entry and never changes.        |
//+------------------------------------------------------------------+
#ifndef GE_RISKMANAGEMENT_MQH
#define GE_RISKMANAGEMENT_MQH

// Global AI Cache variables (shared across ExitContract, EntryGates, AIIntegration)
double g_cachedRegimeTrendProb = 0.5;
double g_cachedRegimeChopProb  = 0.5;

//+------------------------------------------------------------------+
//| Capital Allocation & Auto-Tiering                                |
//+------------------------------------------------------------------+
enum ENUM_CAPITAL_MODE
{
   CAPITAL_MODE_AUTO_TIER,    // Auto-Tier ($1,000 now -> $1,500 @ $3k -> $2,000 @ $4k)
   CAPITAL_MODE_CUSTOM_FIXED, // Custom Fixed Capital (Specified in USD)
   CAPITAL_MODE_FULL_BALANCE  // Full Broker Account Balance
};

enum ENUM_RISK_MODE
{
   RISK_MODE_PERCENT,         // Dynamic % Risk per Trade (e.g. 1.0% - 3.0% of Account Balance)
   RISK_MODE_DYNAMIC_TIER,    // Dynamic Tier Auto-Scaling ($1k -> $25, $2k -> $50, $3k -> $75)
   RISK_MODE_FIXED_USD        // Fixed USD Risk per Trade (Explicit Dollar Amount)
};

input group "=== Capital Allocation & Auto-Tiering ==="
input ENUM_CAPITAL_MODE InpCapitalMode            = CAPITAL_MODE_AUTO_TIER; // Capital Allocation Mode
input double            InpCustomTradingCapitalUSD = 1000.0;                 // Custom Trading Capital in USD (Default $1,000)

input group "=== Risk & Position Sizing ==="
input ulong  InpMagicNumber            = 777999; // Master Magic Number (0 = Manage all trades on symbol)
input bool   InpManageOnlyMagicNumber  = true;   // Only manage/count trades placed by this EA (ignores manual/old trades)
input bool   InpUseConcurrencyCap   = true;    // Enforce the max-position cap and per-trade risk limit
input int    InpMaxConcurrentTrades = 6;       // Max simultaneous positions the EA may hold (Allows Pyramiding)
input int    InpMaxPositionsPerDir  = 6;       // Max simultaneous positions in the same direction (0 = unlimited)
input ENUM_RISK_MODE InpRiskMode        = RISK_MODE_PERCENT; // Risk Calculation Mode (Dynamic % or Fixed USD)
input double InpRiskPercent            = 2.0;     // Target Risk % per trade (Default 2.0% of Balance)
input double InpMaxRiskPercentHardCap  = 3.5;     // Hard Cap Max Risk % per trade (Ceiling)
input double InpRiskPerTradeUSD        = 27.50;   // Target Dollar Risk per trade (Used in Fixed USD mode)
input double InpMaxRiskUSD             = 27.50;   // Target Dollar Risk per trade (Used in Fixed USD mode)
input double InpMaxLossPerTradeUSD     = 30.00;   // Absolute Maximum Hard Cap Dollar Loss (Used in Fixed USD mode)
input double InpMaxRiskHardCapUSD      = 30.00;   // Absolute Ceiling (+10% tolerance on min-lot check)
input double InpMinRiskUSD             = 20.00;   // Floor USD risk per trade ($20.00 USD)
input group "=== Hard Lot Ceilings & Floors ==="
input double InpMinLotSize          = 0.01;    // Minimum Lot Floor (0.01 lots)
input double InpMaxLotSize          = 0.50;    // Absolute Hard Emergency Lot Ceiling Clamp
input double InpHighConfidenceThreshold = 0.65; // Confidence threshold to trigger high conviction lot scaling
input double InpConfidenceBoostMult     = 1.25; // Conviction lot scaling multiplier (capped strictly at InpMaxRiskHardCapUSD)
input group "=== Streak Risk Scaling (multipliers) ==="
input double InpStreakReduceThreeLoss = 0.25;  // Risk multiplier after 3 consecutive losses (shrink size)
input double InpStreakReduceTwoLoss   = 0.50;  // Risk multiplier after 2 consecutive losses (shrink size)
input double InpStreakBoostTwoWin     = 1.25;  // Risk multiplier after 2 consecutive wins (grow size)

//+------------------------------------------------------------------+
//| StreakState — consecutive closed wins/losses for this symbol      |
//| computed from real trade history (HistoryDeals).                  |
//+------------------------------------------------------------------+
struct SStreakState
{
   int    consecutiveLosses;   // 0..N
   int    consecutiveWins;     // 0..N
   bool   hasHistory;          // false = no closed deals found yet
};

//+------------------------------------------------------------------+
//| GetStreakState — scans the most recent closed deals for _Symbol  |
//| and counts the trailing run of wins/losses (break-even deals are  |
//| skipped, they do not break a streak).                            |
//+------------------------------------------------------------------+
SStreakState GetStreakState()
{
   SStreakState s;
   s.consecutiveLosses = 0;
   s.consecutiveWins   = 0;
   s.hasHistory        = false;

   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();

   //--- walk newest first; count the trailing run
   for(int i = total - 1; i >= 0; i--)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;

      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
      if(profit > 0.0)
      {
         s.hasHistory = true;
         s.consecutiveWins++;
      }
      else if(profit < 0.0)
      {
         s.hasHistory = true;
         s.consecutiveLosses++;
      }
      else
         continue;               // break-even: skip, streak continues
      break;                     // only the trailing run counts
   }
   return s;
}

//+------------------------------------------------------------------+
//| StreakMultiplier — returns the risk scaling factor from the      |
//| current streak: shrink after losses, boost after wins.           |
//+------------------------------------------------------------------+
double StreakMultiplier(const SStreakState &s)
{
   if(s.hasHistory)
   {
      if(s.consecutiveLosses >= 3)  return InpStreakReduceThreeLoss;
      if(s.consecutiveLosses >= 2)  return InpStreakReduceTwoLoss;
      if(s.consecutiveWins   >= 2)  return InpStreakBoostTwoWin;
   }
   return 1.0;
}

//+------------------------------------------------------------------+
//| GetISTDateTime — Universal IST clock (GMT + 5:30), broker/VPS    |
//| independent. Immune to foreign VPS timezone discrepancies.       |
//+------------------------------------------------------------------+
void GetISTDateTime(MqlDateTime &dt)
{
   datetime gmt = TimeGMT();
   datetime ist = gmt + (5 * 3600 + 30 * 60); // GMT + 5:30
   TimeToStruct(ist, dt);
}

//+------------------------------------------------------------------+
//| IsZone2Active — check if London/NY peak session (1:30-9:30 PM IST)|
//| is currently active.                                             |
//+------------------------------------------------------------------+
bool IsZone2Active()
{
   MqlDateTime dt;
   GetISTDateTime(dt); // Universal IST clock
   int currentMinutes = dt.hour * 60 + dt.min;
   int startMinutes = 13 * 60 + 30; // 13:30 = 810 mins
   int endMinutes   = 21 * 60 + 30; // 21:30 = 1290 mins
   
   return (currentMinutes >= startMinutes && currentMinutes < endMinutes);
}

//+------------------------------------------------------------------+
//| IsZone3Active — check if Late NY / Night Drift (9:30 PM - 3:30 AM)|
//| is currently active.                                             |
//+------------------------------------------------------------------+
bool IsZone3Active()
{
   MqlDateTime dt;
   GetISTDateTime(dt); // Universal IST clock
   int currentMinutes = dt.hour * 60 + dt.min;
   int z3Start = 21 * 60 + 30; // 21:30 (1290 min)
   int z3End   = 3 * 60 + 30;  // 03:30 (210 min)
   
   return (currentMinutes >= z3Start || currentMinutes < z3End);
}

//+------------------------------------------------------------------+
//| GetAllocatedTradingCapital — Dynamic Tier Ladder & Capital Model |
//+------------------------------------------------------------------+
double GetAllocatedTradingCapital(int &tierNumber)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   tierNumber = 1;

   if(InpCapitalMode == CAPITAL_MODE_CUSTOM_FIXED)
   {
      tierNumber = 1;
      return (InpCustomTradingCapitalUSD > 0.0) ? InpCustomTradingCapitalUSD : 1000.0;
   }

   if(InpCapitalMode == CAPITAL_MODE_FULL_BALANCE)
   {
      tierNumber = 1;
      return (balance > 0.0) ? balance : 1000.0;
   }

   // CAPITAL_MODE_AUTO_TIER:
   // Current Balance $2,511 uses $1,000.
   // Crosses $3,000 -> uses $1,500 (Tier 2).
   // Crosses $4,000 -> uses $2,000 (Tier 3).
   // Crosses $5,000 -> uses $2,500 (Tier 4).
   tierNumber = 1;
   return (InpCustomTradingCapitalUSD > 0.0) ? InpCustomTradingCapitalUSD : 1000.0;
}

//+------------------------------------------------------------------+
//| Market Regime Classification & Thresholds                        |
//+------------------------------------------------------------------+
#define REGIME_TREND_THRESHOLD     25.0    // ADX > 25 = trending
#define REGIME_CHOP_THRESHOLD      50.0    // Choppiness > 50 = chop
#define REGIME_HIGH_VOL_ATR_MULT   1.50    // ATR > 1.5x baseline = high volatility

enum ENUM_REGIME
{
   REGIME_TREND,    // Strong directional trending phase
   REGIME_CHOP,     // Sideways / consolidation / chop phase
   REGIME_HIGH_VOL  // Elevated volatility expansion phase
};

ENUM_REGIME g_currentMarketRegime = REGIME_CHOP;

//+------------------------------------------------------------------+
//| DetectMarketRegime — 100% Native C++ High-Speed Regime Engine     |
//+------------------------------------------------------------------+
ENUM_REGIME DetectMarketRegime()
{
   static int adxH = INVALID_HANDLE;
   static int atrH14 = INVALID_HANDLE;
   static int atrH100 = INVALID_HANDLE;
   
   if(adxH == INVALID_HANDLE) adxH = iADX(_Symbol, PERIOD_M5, 14);
   if(atrH14 == INVALID_HANDLE) atrH14 = iATR(_Symbol, PERIOD_M5, 14);
   if(atrH100 == INVALID_HANDLE) atrH100 = iATR(_Symbol, PERIOD_M5, 100);
   
   double adxBuf[1], atr14Buf[1], atr100Buf[1];
   double adxVal = 20.0, atr14 = 2.0, atr100 = 2.0;
   
   if(adxH != INVALID_HANDLE && CopyBuffer(adxH, 0, 0, 1, adxBuf) > 0) adxVal = adxBuf[0];
   if(atrH14 != INVALID_HANDLE && CopyBuffer(atrH14, 0, 0, 1, atr14Buf) > 0) atr14 = atr14Buf[0];
   if(atrH100 != INVALID_HANDLE && CopyBuffer(atrH100, 0, 0, 1, atr100Buf) > 0) atr100 = atr100Buf[0];
   
   // Native Choppiness Calculation (14 bars) - Zero external indicator lag
   double sumTr = 0.0;
   double maxH = iHigh(_Symbol, PERIOD_M5, 0);
   double minL = iLow(_Symbol, PERIOD_M5, 0);
   for(int k = 0; k < 14; k++)
   {
      double hk = iHigh(_Symbol, PERIOD_M5, k);
      double lk = iLow(_Symbol, PERIOD_M5, k);
      double ck1 = iClose(_Symbol, PERIOD_M5, k + 1);
      double tr = MathMax(hk - lk, MathMax(MathAbs(hk - ck1), MathAbs(lk - ck1)));
      sumTr += tr;
      if(hk > maxH) maxH = hk;
      if(lk < minL) minL = lk;
   }
   double hlRange = maxH - minL;
   double chop = 50.0;
   if(hlRange > 0.0001 && sumTr > 0.0001)
   {
      chop = 100.0 * (MathLog10(sumTr / hlRange) / MathLog10(14.0));
   }
   
   if(adxVal > REGIME_TREND_THRESHOLD && chop < REGIME_CHOP_THRESHOLD)
   {
      g_currentMarketRegime = REGIME_TREND;
   }
   else if(chop > REGIME_CHOP_THRESHOLD || (atr100 > 0.0 && atr14 > atr100 * REGIME_HIGH_VOL_ATR_MULT))
   {
      g_currentMarketRegime = (atr100 > 0.0 && atr14 > atr100 * REGIME_HIGH_VOL_ATR_MULT) ? REGIME_HIGH_VOL : REGIME_CHOP;
   }
   else
   {
      g_currentMarketRegime = REGIME_CHOP;
   }
   
   return g_currentMarketRegime;
}

//+------------------------------------------------------------------+
//| CalculateKellyRiskUSD — Half-Kelly Optimal Fraction Formula      |
//+------------------------------------------------------------------+
double CalculateKellyRiskUSD(double winRate, double avgWinRatio, double accountBalance)
{
   // Kelly Criterion: f* = (p * b - q) / b
   // where p = winRate, q = 1 - p, b = avgWinRatio
   double q = 1.0 - winRate;
   double b = MathMax(avgWinRatio, 0.1);
   
   double kellyFraction = (winRate * b - q) / b;
   
   // Half-Kelly for safety (optimal geometric growth with controlled variance)
   kellyFraction = kellyFraction * 0.5;
   
   // Clamp between 0.5% (0.005) and 4.0% (0.04) of account
   kellyFraction = MathMax(0.005, MathMin(0.04, kellyFraction));
   
   return accountBalance * kellyFraction;
}

//+------------------------------------------------------------------+
//| CalculateLotSizeWithConfidence — Regime-Adjusted Kelly Sizing    |
//+------------------------------------------------------------------+
double CalculateLotSizeWithConfidence(const double slDistUSD, const string source, const string dir, const double confidence, const double minConfidence)
{
   if(slDistUSD <= 0.0)
      return 0.0;

   DetectMarketRegime();

   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(point <= 0.0 || tickVal <= 0.0 || tickSize <= 0.0)
      return 0.01;
   if(lotStep <= 0.0) lotStep = 0.01;
   if(minLot <= 0.0)  minLot  = 0.01;
   if(maxLot <= 0.0)  maxLot  = 100.0;

   double riskPoints       = slDistUSD / point;
   double valuePerPointLot = tickVal * (point / tickSize);
   double riskPerLot       = riskPoints * valuePerPointLot;
   if(riskPerLot <= 0.0) return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) balance = 1000.0;

   // 1. Tier-specific win rates and payout ratios (from out-of-sample data)
   double winRate = 0.5207, avgWinRatio = 1.19; // Core tier
   if(confidence >= 0.68)
   {
      winRate = 0.7308; avgWinRatio = 2.71;    // Apex tier (73% WR, 2.71 PF)
   }
   else if(confidence >= 0.62)
   {
      winRate = 0.5601; avgWinRatio = 1.27;    // Sniper tier (56% WR, 1.27 PF)
   }

   // 2. Base Half-Kelly Risk in USD
   double baseRiskUSD = CalculateKellyRiskUSD(winRate, avgWinRatio, balance);

   // 3. REGIME MULTIPLIERS
   double regimeMultiplier = 1.0;
   switch(g_currentMarketRegime)
   {
      case REGIME_TREND:    regimeMultiplier = 1.20; break; // +20% in trends (edge is strongest)
      case REGIME_CHOP:     regimeMultiplier = 0.40; break; // -60% in chop (edge is weaker)
      case REGIME_HIGH_VOL: regimeMultiplier = 0.60; break; // -40% in high volatility (wider stops)
   }

   // 4. CONVICTION MULTIPLIERS
   double convictionMultiplier = 1.0;
   if(confidence >= 0.68)      convictionMultiplier = 1.50; // Apex: 1.5x
   else if(confidence >= 0.62) convictionMultiplier = 1.20; // Sniper: 1.2x
   else if(confidence >= 0.58) convictionMultiplier = 1.00; // Core: 1.0x
   else                        convictionMultiplier = 0.50; // Low confidence: 0.5x

   // 5. Streak multiplier
   SStreakState streak = GetStreakState();
   double streakMult = StreakMultiplier(streak);

   // 6. Calculate Final Risk in USD
   double finalRiskUSD = baseRiskUSD * regimeMultiplier * convictionMultiplier * streakMult;
   
   // Hard dynamic limits ($5 min, max 4.5% of balance)
   double maxAllowedRiskUSD = balance * (InpMaxRiskPercentHardCap / 100.0);
   finalRiskUSD = MathMax(5.0, MathMin(maxAllowedRiskUSD, finalRiskUSD));

   // 7. Convert Risk USD to Lot Size
   double targetLot = finalRiskUSD / riskPerLot;
   targetLot = MathFloor(targetLot / lotStep) * lotStep;

   // 8. Min/Max Lot Clamps
   if(targetLot < minLot)
   {
      double minLotRiskUSD = minLot * riskPerLot;
      if(minLotRiskUSD > maxAllowedRiskUSD * 1.25)
      {
         PrintFormat("[RiskGovernor REJECT] Min lot (%.2f) risks $%.2f > Hard Cap $%.2f (Stop $%.2f too wide for balance $%.2f)",
                     minLot, minLotRiskUSD, maxAllowedRiskUSD, slDistUSD, balance);
         return 0.0;
      }
      targetLot = minLot;
   }

   if(targetLot > InpMaxLotSize) targetLot = InpMaxLotSize;
   if(targetLot > maxLot) targetLot = maxLot;
   targetLot = NormalizeDouble(targetLot, 2);

   double actualRiskUSD = targetLot * riskPerLot;
   PrintFormat("[KellyRiskGovernor] SL: $%.2f | Lots: %.2f | Risk: $%.2f | Regime: %s (x%.2f) | Conviction: %.2f (x%.2f) | Balance: $%.2f",
               slDistUSD, targetLot, actualRiskUSD, (g_currentMarketRegime == REGIME_TREND ? "TREND" : (g_currentMarketRegime == REGIME_HIGH_VOL ? "HIGH_VOL" : "CHOP")),
               regimeMultiplier, confidence, convictionMultiplier, balance);

   return targetLot;
}

double CalculatePositionSize(double confidence, double slDistUSD)
{
   return CalculateLotSizeWithConfidence(slDistUSD, "KELLY", "AUTO", confidence, 0.55);
}

//+------------------------------------------------------------------+
//| MT5 Native Economic Calendar News Filter & Pre-News Guard        |
//+------------------------------------------------------------------+
input group "=== MT5 Native Economic Calendar News Filter ==="
input bool   InpUseNewsFilter             = true;   // Enable MT5 Native Economic Calendar News Filter
input int    InpNewsBufferBeforeMin       = 15;     // Minutes to pause new entries BEFORE high-impact USD news
input int    InpNewsBufferAfterMin        = 15;     // Minutes to pause new entries AFTER high-impact USD news
input bool   InpUseNewsPositionGuard      = true;   // Pre-News Position Guard (Protect Profit / Cut Loss)
input int    InpNewsCutLossMinutesBefore  = 3;      // Close losing trades X minutes before high-impact news (e.g. 3 mins)
input bool   InpNewsLockProfitToBE        = true;   // Move SL to Break-Even for winning trades before news
input double InpNewsBELockBufferUSD       = 0.50;   // Break-Even profit lock buffer in USD above entry

//+------------------------------------------------------------------+
//| IsHighImpactNewsActive — query MT5 Native Economic Calendar for  |
//| high-impact USD events within the before/after time buffers.     |
//+------------------------------------------------------------------+
bool IsHighImpactNewsActive(string &eventName)
{
   if(!InpUseNewsFilter) return false;
   eventName = "";
   
   datetime now = TimeCurrent();
   datetime fromTime = now - (InpNewsBufferAfterMin * 60);
   datetime toTime   = now + (InpNewsBufferBeforeMin * 60);

   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, fromTime, toTime, "US", "USD");
   if(total <= 0) return false;

   for(int i = 0; i < total; i++)
   {
      MqlCalendarEvent event;
      if(CalendarEventById(values[i].event_id, event))
      {
         if(event.importance == CALENDAR_IMPORTANCE_HIGH)
         {
            eventName = event.name;
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| IsHighImpactNewsUpcoming — check if high-impact news is due in X |
//| minutes (used for pre-news position safety guard).               |
//+------------------------------------------------------------------+
bool IsHighImpactNewsUpcoming(int minutesBefore, string &eventName)
{
   if(!InpUseNewsFilter && !InpUseNewsPositionGuard) return false;
   eventName = "";
   
   datetime now = TimeCurrent();
   datetime fromTime = now;
   datetime toTime   = now + (minutesBefore * 60);

   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, fromTime, toTime, "US", "USD");
   if(total <= 0) return false;

   for(int i = 0; i < total; i++)
   {
      MqlCalendarEvent event;
      if(CalendarEventById(values[i].event_id, event))
      {
         if(event.importance == CALENDAR_IMPORTANCE_HIGH)
         {
            eventName = event.name;
            return true;
         }
      }
   }
   return false;
}

bool g_killSwitchBtnActive = false; // Toggled by the chart dashboard button
double g_cachedRsi = 50.0;          // Cached RSI value, written by AI layer, read by entry gates

#endif // GE_RISKMANAGEMENT_MQH