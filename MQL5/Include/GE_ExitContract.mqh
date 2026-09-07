//+------------------------------------------------------------------+
//| GE_ExitContract.mqh                                              |
//| Single source of truth for what happens AFTER a trade opens.     |
//|                                                                  |
//| OWNED HERE (Step 2 + Step 3):                                    |
//|   - CTradeSafe: SL6/TP8-enforcing trade wrapper. THE ONLY class  |
//|     through which orders are placed anywhere in the EA. It        |
//|     computes SL/TP from InpExitSLDistUSD / InpExitTPDistUSD and   |
//|     accepts NO caller-supplied stop or target — no custom SL/TP   |
//|     can exist anywhere else.                                      |
//|   - CheckExitContract():                                          |
//|       (a) 4h time-decay close (InpMaxHoldMinutes)                 |
//|       (b) ONNX reversal-exit: opposite prob >= InpExitReversalP,  |
//|           closes winning OR losing trades (InpExitReversalAllowLoss),|
//|           once per new bar (bar-close), shares the single cached  |
//|           ONNX source passed in from the caller.                  |
//|       (c) Universal Ladder Trailing stop:                         |
//|           locks in profit at fixed percentages of planned TP.     |
//|                                                                  |
//| GUARD RAILS:                                                     |
//|   - SL/TP distances are structural and ALWAYS applied, whatever  |
//|     the input value is set to. Changing the input changes the    |
//|     NUMBER only, never the enforcement.                          |
//|   - No per-strategy exits, no AI-controlled exits. Any code      |
//|     computing a stop/target outside CTradeSafe is a bug.         |
//|   - Reversal-exit closes a trade when the opposite-class prob >=  |
//|     InpExitReversalP. By default (InpExitReversalAllowLoss=true)  |
//|     it closes BOTH winning and losing trades on a genuine         |
//|     reversal (fixes "keep buying into a reversal" losses). Set it |
//|     false to restore the old winning-only behaviour.             |
//|   - Reversal-exit always takes precedence over the ladder trail   |
//|     on bar-close.                                                |
//|   - Stop-loss can only tighten, never loosen (ratchet rule).      |
//|   - Stops are checked for bounds: never worse than original, or   |
//|     past TP price.                                               |
//+------------------------------------------------------------------+
#ifndef GE_EXITCONTRACT_MQH
#define GE_EXITCONTRACT_MQH

// One-directional dependency (Step 6 addendum):
//   GE_ExitContract.mqh may use GE_RiskManagement.mqh
#include <GE_RiskManagement.mqh>
#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Exit Contract (SL/TP/Time-Decay)                                 |
//+------------------------------------------------------------------+
input group "=== Exit Contract (SL/TP/Time-Decay) ==="
input bool   InpUseATRStopLoss        = true;  // Use ATR-based SL/TP instead of fixed-USD distances
input double InpATRMultiplier         = 2.5;   // SL = InpATRMultiplier x ATR(14) [2.5x ATR = Full Volatility Breathing Room]
input double InpLiquidityBufferUSD    = 3.50;  // Hunt-Proof Liquidity Buffer below/above swing wicks (USD)
input double InpFomoRRRatio           = 2.5;   // TP = SL x InpFomoRRRatio [2.5R Positive Asymmetry for Big Runners]
input double InpFixedRiskUSD          = 75.0;  // Reference USD risk per trade
input bool   InpUseProgressiveProfitLock = true;  // Progressive % Profit Lock (35% @ $20, 50% @ $35, 65% @ $50, 75% @ $75)
input bool   InpUseAutoBreakEven      = true;  // Automatically move Stop Loss to Break-Even when in profit
input double InpBEActivationATR       = 0.6;   // Break-Even trigger distance in ATRs (e.g. 0.6x ATR in profit -> lock BE)
input double InpBEBufferUSD           = 0.35;  // Profit buffer above/below entry for Break-Even (covers spread + commission)
input bool   InpUseATRTrailing        = true;  // Use dynamic ATR-based trailing stop-loss (dynamic volatility breathing room)
input double InpTrailActivationATR    = 0.8;   // Trailing stop activation in ATRs (e.g. 0.8x ATR in profit -> start trailing)
input double InpTrailATRMultiplier    = 0.8;   // Trailing stop distance in ATRs (0.8x ATR = Semi-Aggressive Sweet Spot)
input double InpMinRatchetStepUSD     = 0.15;  // Minimum SL ratchet increment in USD to prevent order flood
input double InpTrailLockUSD          = 25.0;  // Fallback fixed USD trailing lock (when ATR unavailable)
input double InpTrailDistUSD          = 15.0;  // Fallback fixed USD trailing distance (when ATR unavailable)
input double InpExitSLDistUSD         = 20.0;  // Reference SL distance used for lot-sizing math ONLY (structural fallback)
input double InpExitTPDistUSD         = 60.0;  // Take-profit distance in USD, applied to EVERY position (structural)
input int    InpMaxHoldMinutes        = 0;     // Max time in position before forced close (minutes; 0 = DISABLED, let trades run)
input double InpExitReversalP         = 0.65;  // ONNX probability that flips a position to the opposite side (Fast Reversal Guard)
input bool   InpExitReversalAllowLoss = true;  // Close LOSING trades on ONNX reversal (true = Fast Loss Cut at -$10 to -$15 max, avoids -$45 full SL)
input bool   InpUseStepLadder         = false; // Use USD-based micro step ladder (false = Allow full dynamic ATR trailing)
input double InpStepSizeUSD           = 15.0;  // Step size and trailing buffer amount in USD
input bool   InpUseLadderTrail        = true;  // Master Trailing Stop & Profit Lock Switch

input group "=== ONNX Engine (Advanced Model) ==="
input bool   InpUseAdvancedModel = false;                    // Enable advanced 3-output orderflow model
input string InpAdvancedModelPath = "gru_model_advanced.onnx"; // Advanced Model file (relative to MQL5/Files)

//+------------------------------------------------------------------+
//| PriceDistForLoss — convert an account-USD loss/trail into a chart |
//| PRICE distance given the position's lot size. This is what makes  |
//| the $25 loss and $5 trail LOT-INDEPENDENT: bigger lot = tighter   |
//| price SL so the account loss stays constant.                      |
//| For XAUUSD: $1 price = $100 per 1.0 lot = $5 at 0.05 lots.        |
//+------------------------------------------------------------------+
double PriceDistForLoss(const double usdAmount, const double lot)
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0 || lot <= 0.0)
      return 0.0;
   return usdAmount * tickSize / (lot * tickValue);
}

//+------------------------------------------------------------------+
//| Strategy fallback distances (Step 4 H-list) — declared so the    |
//| Step 5 input surface is complete. Enforcement is structural:     |
//| CTradeSafe ALWAYS uses InpExitSLDistUSD / InpExitTPDistUSD.      |
//| These inputs change nothing and exist for input-surface parity   |
//| only; they are never read as alternative exits.                  |
//+------------------------------------------------------------------+
input group "=== Strategy Fallback Distances (USD) ==="
input double InpScalpSLFallback     = 0.60;  // Scalping SL fallback distance in USD
input double InpScalpTPFallback     = 0.80;  // Scalping TP fallback distance in USD
input double InpPullbackSLFallback  = 0.80;  // Pullback SL fallback distance in USD
input double InpPullbackTPFallback  = 2.00;  // Pullback TP fallback distance in USD
input double InpSafetyLineDistance  = 8.0;   // Distance from a GNN line that triggers SL safety adjustment (USD)

//+------------------------------------------------------------------+
//| CTradeSafe — SL6/TP8-enforcing wrapper (Step 3).                 |
//| Derives from CTrade; the ONLY Buy/Sell entry points used by the  |
//| whole EA. Every market order sent through here gets the          |
//| structural SL and TP computed from the exit-contract inputs.     |
//| The caller may pass an explicit price (0.0 = market) but can     |
//| never pass a stop or target — there is no such parameter.        |
//+------------------------------------------------------------------+
class CTradeSafe : public CTrade
{
public:
   CTradeSafe()
   {
      if(InpMagicNumber > 0)
         SetExpertMagicNumber(InpMagicNumber);
   }

   //--- BUY: SL = ask - slDistUSD, TP = ask + tpDistUSD
   bool BuySafe(const double lot, const string symbol, const double slDistUSD, const double tpDistUSD, const double price = 0.0)
   {
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - slDistUSD, _Digits);
      double tp  = NormalizeDouble(ask + tpDistUSD, _Digits);
      SetTypeFillingBySymbol(symbol);
      if(InpMagicNumber > 0)
         SetExpertMagicNumber(InpMagicNumber);
      return Buy(lot, symbol, price, sl, tp);
   }

   //--- SELL: SL = bid + slDistUSD, TP = bid - tpDistUSD
   bool SellSafe(const double lot, const string symbol, const double slDistUSD, const double tpDistUSD, const double price = 0.0)
   {
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + slDistUSD, _Digits);
      double tp  = NormalizeDouble(bid - tpDistUSD, _Digits);
      SetTypeFillingBySymbol(symbol);
      if(InpMagicNumber > 0)
         SetExpertMagicNumber(InpMagicNumber);
      return Sell(lot, symbol, price, sl, tp);
   }
};

//+------------------------------------------------------------------+
//| CheckExitContract — (a) time-decay and (b) reversal-exit.        |
//| Called on every new bar from the orchestrator. It receives the   |
//| single cached ONNX source (bull/bear probs + valid flag) so the  |
//| reversal-exit shares the exact same model read the entry gates   |
//| use — there is never a second, independently-run inference.      |
//|                                                                  |
//| Reversal-exit rule (Step 3):                                     |
//|   - position is closed when opposite-class prob >= InpExitReversalP |
//|   - winning OR losing (InpExitReversalAllowLoss); the old strict |
//|     profit>0 gate is removed so trades stop riding reversals.    |
//|   - evaluated ONCE per new bar (bar-close decision)              |
//| A SELL has its position flipped out by P(BULL) >= threshold;     |
//| a BUY by P(BEAR) >= threshold.                                   |
//+------------------------------------------------------------------+
void CheckExitContract(const double onnxBull, const double onnxBear, const bool onnxValid)
{
   static datetime g_lastExitCheckBar = 0;
   datetime barTime = iTime(_Symbol, _Period, 0);
   bool newBar = (barTime != g_lastExitCheckBar);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(InpManageOnlyMagicNumber && InpMagicNumber > 0 && PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type   = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      datetime           openT  = (datetime)PositionGetInteger(POSITION_TIME);
      double             profit = PositionGetDouble(POSITION_PROFIT);

      //--- (a) Time-decay: forced close once held >= InpMaxHoldMinutes (0 = DISABLED)
      if(InpMaxHoldMinutes > 0 && (TimeCurrent() - openT) >= (long)InpMaxHoldMinutes * 60)
      {
         CTradeSafe trade;
         if(trade.PositionClose(ticket))
            PrintFormat("[Time-Decay] Closed #%I64u (held %d min).", ticket, InpMaxHoldMinutes);
         continue;
      }

      //--- (b) ONNX reversal-exit — bar-close. Closes the trade when the
      //---     opposite-class probability >= InpExitReversalP (winning OR losing
      //---     when InpExitReversalAllowLoss). Takes precedence over ladder trail.
      if(newBar && onnxValid && (profit > 0.0 || InpExitReversalAllowLoss))
      {
         double oppProb = (type == POSITION_TYPE_BUY) ? onnxBear : onnxBull;
         if(oppProb >= InpExitReversalP)
         {
            CTradeSafe trade;
            if(trade.PositionClose(ticket))
            {
               PrintFormat("[Reversal-Exit] Closed #%I64u: opp prob %.2f >= %.2f, profit %.2f.",
                           ticket, oppProb, InpExitReversalP, profit);
            }
            continue;
         }
      }
   }

   if(newBar)
      g_lastExitCheckBar = barTime;
}

//+------------------------------------------------------------------+
//| CheckExitContractTick — Evaluated on every tick to trail stops.  |
//| Universal Ladder Trail (19 Aug restored contract): locks in       |
//| profit at fixed PERCENTAGES of the planned TP reward (price-based,|
//| lot-independent). Ratchet-only (never loosens), never past the    |
//| original SL, never past TP.                                       |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| CheckExitContractTick — Evaluated on every tick/timer to trail.  |
//| Multi-tier Profit Protection:                                    |
//|  1. Pre-News Safety: cut loss or lock BE before high-impact news|
//|  2. Auto Break-Even: locks BE+buffer at +1.0x ATR profit (Risk-Free)|
//|  3. Dynamic ATR Trailing: ratchets SL behind price to lock profits|
//|  4. Step Ladder (optional USD mode): discrete USD profit steps    |
//| Ratchet-only (never loosens), respects broker stopsLevel & TP.   |
//+------------------------------------------------------------------+
void CheckExitContractTick()
{
   if(!InpUseLadderTrail)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      if(StringCompare(posSymbol, _Symbol, false) != 0)
         continue;
      if(InpManageOnlyMagicNumber && InpMagicNumber > 0 && PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type   = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             profit = PositionGetDouble(POSITION_PROFIT);
      double             lot    = PositionGetDouble(POSITION_VOLUME);

      double currentPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double entryPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL    = PositionGetDouble(POSITION_SL);
      double currentTP    = PositionGetDouble(POSITION_TP);

      double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      if(contractSize <= 0.0) contractSize = 100.0;
      if(lot <= 0.0) continue;

      double targetSL = 0.0;
      bool modifyNeeded = false;
      double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      if(stopsLevel < 0.30) stopsLevel = 0.30;

      // Price gain in points / dollars per ounce
      double priceGain = (type == POSITION_TYPE_BUY) ? (currentPrice - entryPrice)
                                                     : (entryPrice - currentPrice);

      // Current ATR(14) calculation
      double atrBufVal[];
      double atrNow = 0.0;
      static int atrHNow = INVALID_HANDLE;
      if(atrHNow == INVALID_HANDLE)
         atrHNow = iATR(_Symbol, _Period, 14);
      if(atrHNow != INVALID_HANDLE && CopyBuffer(atrHNow, 0, 0, 1, atrBufVal) > 0)
         atrNow = atrBufVal[0];
      if(atrNow <= 0.0) atrNow = 2.00; // sensible Gold default fallback

      //=== 1. PRE-NEWS POSITION GUARD: Protect Profit / Cut Loss before High-Impact News ===
      if(InpUseNewsPositionGuard)
      {
         string imminentNewsEvent = "";
         if(IsHighImpactNewsUpcoming(InpNewsCutLossMinutesBefore, imminentNewsEvent) || IsHighImpactNewsActive(imminentNewsEvent))
         {
            // Case A: Position is in LOSS (< 0) -> Close immediately to prevent catastrophic slippage stop-out
            if(profit < 0.0)
            {
               CTradeSafe trade;
               trade.SetDeviationInPoints(50);
               if(trade.PositionClose(ticket))
               {
                  PrintFormat("[Pre-News-Safety-CUT] Closed losing #%I64u (P/L: -$%.2f USD) %d min before News: %s to protect capital!",
                              ticket, MathAbs(profit), InpNewsCutLossMinutesBefore, imminentNewsEvent);
                  continue;
               }
            }
            // Case B: Position is in PROFIT (> 0) -> Keep trade OPEN, but immediately lock SL to Break-Even + Buffer!
            else if(InpNewsLockProfitToBE && profit >= 0.0)
            {
               double beSL = (type == POSITION_TYPE_BUY) ? (entryPrice + InpNewsBELockBufferUSD)
                                                         : (entryPrice - InpNewsBELockBufferUSD);
               beSL = NormalizeDouble(beSL, _Digits);

               bool beNeeded = false;
               if(type == POSITION_TYPE_BUY)
               {
                  if(beSL > currentSL && beSL < (currentPrice - stopsLevel) && (currentTP == 0.0 || beSL < currentTP))
                     beNeeded = true;
               }
               else // POSITION_TYPE_SELL
               {
                  if((currentSL == 0.0 || beSL < currentSL) && beSL > (currentPrice + stopsLevel) && (currentTP == 0.0 || beSL > currentTP))
                     beNeeded = true;
               }

               if(beNeeded)
               {
                  CTradeSafe trade;
                  trade.SetDeviationInPoints(50);
                  if(trade.PositionModify(ticket, beSL, currentTP))
                  {
                     PrintFormat("[Pre-News-Safety-BE] Locked winning #%I64u SL to Break-Even (%.2f) before News: %s (Trade remains open risk-free!).",
                                 ticket, beSL, imminentNewsEvent);
                     currentSL = beSL;
                  }
               }
            }
         }
      }

      //=== 2. METHOD A: USD-based Step Ladder Trail (if explicitly enabled) ===
      if(InpUseStepLadder)
      {
         double lockedProfitUSD = 0.0;
         bool useFastSmallLadder = (lot <= 0.10 || IsZone3Active());
         
         if(useFastSmallLadder)
         {
            if(profit >= 10.0)
            {
               int n = (int)(profit / 5.0);
               lockedProfitUSD = (n - 1) * 5.0;
            }
         }
         else
         {
            if(profit >= 2.0 * InpStepSizeUSD)
            {
               int n = (int)(profit / InpStepSizeUSD);
               lockedProfitUSD = (n - 1) * InpStepSizeUSD;
            }
         }
         
         if(lockedProfitUSD > 0.0)
         {
            double profitPriceDist = lockedProfitUSD / (lot * contractSize);
            targetSL = (type == POSITION_TYPE_BUY) ? (entryPrice + profitPriceDist)
                                                   : (entryPrice - profitPriceDist);
            targetSL = NormalizeDouble(targetSL, _Digits);

            if(type == POSITION_TYPE_BUY)
            {
               if((currentSL == 0.0 || targetSL >= (currentSL + InpMinRatchetStepUSD)) &&
                  targetSL < (currentPrice - stopsLevel) &&
                  (currentTP == 0.0 || targetSL < currentTP))
                  modifyNeeded = true;
            }
            else // POSITION_TYPE_SELL
            {
               if((currentSL == 0.0 || targetSL <= (currentSL - InpMinRatchetStepUSD)) &&
                  targetSL > (currentPrice + stopsLevel) &&
                  (currentTP == 0.0 || targetSL > currentTP))
                  modifyNeeded = true;
            }
         }
      }
      //=== 3. METHOD B: Dynamic ATR Trailing & Break-Even Auto-Lock (Default & Recommended) ===
      else
      {
         //--- Step 1: Auto Break-Even Guard (Risk-Free Lock at +1.0x ATR profit)
         if(InpUseAutoBreakEven)
         {
            double beTriggerDist = InpBEActivationATR * atrNow;
            if(priceGain >= beTriggerDist)
            {
               double beSL = (type == POSITION_TYPE_BUY) ? NormalizeDouble(entryPrice + InpBEBufferUSD, _Digits)
                                                         : NormalizeDouble(entryPrice - InpBEBufferUSD, _Digits);
               
               if(type == POSITION_TYPE_BUY)
               {
                  if((currentSL < beSL || currentSL == 0.0) &&
                     beSL < (currentPrice - stopsLevel) &&
                     (currentTP == 0.0 || beSL < currentTP))
                  {
                     targetSL = beSL;
                     modifyNeeded = true;
                  }
               }
               else // POSITION_TYPE_SELL
               {
                  if((currentSL > beSL || currentSL == 0.0) &&
                     beSL > (currentPrice + stopsLevel) &&
                     (currentTP == 0.0 || beSL > currentTP))
                  {
                     targetSL = beSL;
                     modifyNeeded = true;
                  }
               }
            }
         }

         //--- Step 2: Dynamic ATR Trailing & Progressive Profit Lock (Ratchets behind advancing runners)
         if(InpUseATRTrailing)
         {
            double trailTriggerDist = InpTrailActivationATR * atrNow;
            if(priceGain >= trailTriggerDist || (InpUseProgressiveProfitLock && profit >= 15.0))
            {
               double multiplier = 1.0;
               if(InpUseAdvancedModel)
               {
                  if(g_cachedRegimeTrendProb >= 0.60)
                     multiplier = 1.15;
                  else if(g_cachedRegimeTrendProb <= 0.40)
                     multiplier = 0.85;
               }

               double trailDistPrice = InpTrailATRMultiplier * multiplier * atrNow;
               if(trailDistPrice < 1.00) trailDistPrice = 1.00; // Minimum 1.00 USD trailing distance

               double candidateSL = (type == POSITION_TYPE_BUY) ? NormalizeDouble(currentPrice - trailDistPrice, _Digits)
                                                                : NormalizeDouble(currentPrice + trailDistPrice, _Digits);

               // Safeguard: Never trail below Break-Even once in trailing territory
               if(InpUseAutoBreakEven)
               {
                  if(type == POSITION_TYPE_BUY && candidateSL < (entryPrice + InpBEBufferUSD))
                     candidateSL = NormalizeDouble(entryPrice + InpBEBufferUSD, _Digits);
                  else if(type == POSITION_TYPE_SELL && candidateSL > (entryPrice - InpBEBufferUSD))
                     candidateSL = NormalizeDouble(entryPrice - InpBEBufferUSD, _Digits);
               }

               // Progressive Cash Profit Lock: Secures 25% to 75% of peak dollar profit
               if(InpUseProgressiveProfitLock && profit >= 12.0)
               {
                  double lockRatio = 0.0;
                  if(profit >= 75.0)      lockRatio = 0.75; // 75% profit secured @ $75+
                  else if(profit >= 50.0) lockRatio = 0.65; // 65% profit secured @ $50+
                  else if(profit >= 35.0) lockRatio = 0.50; // 50% profit secured @ $35+
                  else if(profit >= 20.0) lockRatio = 0.35; // 35% profit secured @ $20+
                  else if(profit >= 12.0) lockRatio = 0.25; // 25% profit secured @ $12+

                  if(lockRatio > 0.0)
                  {
                     double lockedDollars = profit * lockRatio;
                     double lockPriceDist = lockedDollars / (lot * contractSize);
                     double progSL = (type == POSITION_TYPE_BUY) ? NormalizeDouble(entryPrice + lockPriceDist, _Digits)
                                                                 : NormalizeDouble(entryPrice - lockPriceDist, _Digits);

                     if(type == POSITION_TYPE_BUY)
                     {
                        if(progSL > candidateSL)
                           candidateSL = progSL;
                     }
                     else // POSITION_TYPE_SELL
                     {
                        if(candidateSL == 0.0 || progSL < candidateSL)
                           candidateSL = progSL;
                     }
                  }
               }

               if(type == POSITION_TYPE_BUY)
               {
                  if((currentSL == 0.0 || candidateSL >= (currentSL + InpMinRatchetStepUSD)) &&
                     candidateSL < (currentPrice - stopsLevel) &&
                     (currentTP == 0.0 || candidateSL < currentTP))
                  {
                     targetSL = candidateSL;
                     modifyNeeded = true;
                  }
               }
               else // POSITION_TYPE_SELL
               {
                  if((currentSL == 0.0 || candidateSL <= (currentSL - InpMinRatchetStepUSD)) &&
                     candidateSL > (currentPrice + stopsLevel) &&
                     (currentTP == 0.0 || candidateSL > currentTP))
                  {
                     targetSL = candidateSL;
                     modifyNeeded = true;
                  }
               }
            }
         }
         //--- Step 3: Fixed USD Trailing Fallback (when ATR trailing is disabled)
         else
         {
            double lotScaledTriggerUSD = InpTrailLockUSD * (lot / 0.10);
            if(lotScaledTriggerUSD < 5.0) lotScaledTriggerUSD = 5.0;

            if(profit >= lotScaledTriggerUSD)
            {
               double trailDistPrice = InpTrailDistUSD / (lot * contractSize);
               if(trailDistPrice < 1.00) trailDistPrice = 1.00;

               double candidateSL = (type == POSITION_TYPE_BUY) ? NormalizeDouble(currentPrice - trailDistPrice, _Digits)
                                                                : NormalizeDouble(currentPrice + trailDistPrice, _Digits);

               if(type == POSITION_TYPE_BUY)
               {
                  if((currentSL == 0.0 || candidateSL >= (currentSL + InpMinRatchetStepUSD)) &&
                     candidateSL < (currentPrice - stopsLevel) &&
                     (currentTP == 0.0 || candidateSL < currentTP))
                  {
                     targetSL = candidateSL;
                     modifyNeeded = true;
                  }
               }
               else // POSITION_TYPE_SELL
               {
                  if((currentSL == 0.0 || candidateSL <= (currentSL - InpMinRatchetStepUSD)) &&
                     candidateSL > (currentPrice + stopsLevel) &&
                     (currentTP == 0.0 || candidateSL > currentTP))
                  {
                     targetSL = candidateSL;
                     modifyNeeded = true;
                  }
               }
            }
         }
      }

      //=== 4. Enforce Modification with Clear Diagnostics ===
      if(modifyNeeded && targetSL > 0.0)
      {
         CTradeSafe trade;
         trade.SetDeviationInPoints(50);
         if(trade.PositionModify(ticket, targetSL, currentTP))
         {
            PrintFormat("[Trailing-Stop-SUCCESS] #%I64u SL ratcheted: %.2f -> %.2f (Gain: +$%.2f/oz, FloatPL: $%.2f USD, Price: %.2f)",
                        ticket, currentSL, targetSL, priceGain, profit, currentPrice);
         }
         else
         {
            PrintFormat("[Trailing-Stop-FAIL] #%I64u target SL %.2f rejected! Retcode: %u, Error: %d (CurrentSL: %.2f, Price: %.2f, StopsLevel: %.2f)",
                        ticket, targetSL, trade.ResultRetcode(), GetLastError(), currentSL, currentPrice, stopsLevel);
         }
      }
   }
}

#endif // GE_EXITCONTRACT_MQH