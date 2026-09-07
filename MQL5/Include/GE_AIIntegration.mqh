//+------------------------------------------------------------------+
//| GE_AIIntegration.mqh                                             |
//| Owns the AI/ONNX strategy layer.                                 |
//|                                                                  |
//| OWNED HERE (Step 8):                                             |
//|   - The THREE actual AI prompts, embedded verbatim as templates  |
//|   - Prompt builders that substitute real market values           |
//|   - JSON parsers — each reads ONLY the fields its prompt asks    |
//|     for; no parser expects a field the prompt no longer requests |
//|     (expected_hold_bars, stop_loss_price, take_profit_price,     |
//|     horizon are permanently excluded — confirmed dead).          |
//|                                                                  |
//| NOT OWNED HERE: whether a strategy is ALLOWED to fire — that is  |
//|   GE_EntryGates.mqh's job via the ONNX permission check.         |
//+------------------------------------------------------------------+
#ifndef GE_AIINTEGRATION_MQH
#define GE_AIINTEGRATION_MQH

// One-directional dependency (Step 6 addendum):
//   GE_AIIntegration.mqh may use GE_EntryGates.mqh, GE_ExitContract.mqh,
//   GE_RiskManagement.mqh. It calls INTO GE_EntryGates.mqh to request
//   permission; it is never included BY GE_EntryGates.mqh (no cycle).
#include <GE_RiskManagement.mqh>
#include <GE_ExitContract.mqh>
#include <GE_EntryGates.mqh>
#include <GRUStats76.mqh>
#include <GE_AdvancedModel.mqh>
#include <GoldAI_Features.mqh>
#include <GoldAI_ONNXEngine.mqh>
#include <GE_MLPEngine.mqh>
#include <GE_RulesEngine.mqh>

CGoldAIFeatures   g_features42;
CGoldAIONNXEngine g_onnx42;
CGoldAIMLPEngine  g_mlpEngine;
string            g_activeTradeSetup = "NONE";

struct EnsembleResult
{
   int    finalDirection;       // 0=Bull, 1=Neutral, 2=Bear
   double ensembleConfidence;
   bool   execute;
   string reason;
};

//+------------------------------------------------------------------+
//| EnsembleVote — 3-Way Weighted Multi-Model Consensus Engine       |
//| LightGBM GBDT (50%) + MLP Neural Net (30%) + Structural Rules (20%)
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| EnsembleVote — Smart Dual-Engine Solo Specialist & Synergy Router |
//| Mode 1: Solo Specialist Strike (LGBM >= 0.58 or MLP >= 0.68)      |
//| Mode 2: Dual-Engine Synergy (Both agree >= 0.52 -> 1.20x Boost)   |
//| Mode 3: Regime-Aware Tie-Breaker (ADX > 25 Trend | Chop Range)   |
//+------------------------------------------------------------------+
EnsembleResult EnsembleVote(const float &lgbmProbs[], const float &mlpProbs[], const RuleSignal &rule)
{
   EnsembleResult result;
   result.finalDirection     = 1;
   result.ensembleConfidence = 0.0;
   result.execute            = false;
   result.reason             = "NO_CONSENSUS";

   // 1. Detect live market regime
   ENUM_REGIME regime = DetectMarketRegime();

   // 2. Identify primary directional lean of each model
   bool lgbmIsBull = (lgbmProbs[0] > lgbmProbs[2] && lgbmProbs[0] > lgbmProbs[1]);
   bool lgbmIsBear = (lgbmProbs[2] > lgbmProbs[0] && lgbmProbs[2] > lgbmProbs[1]);
   double lgbmTopProb = MathMax(lgbmProbs[0], lgbmProbs[2]);

   bool mlpIsBull  = (mlpProbs[0] > mlpProbs[2] && mlpProbs[0] > mlpProbs[1]);
   bool mlpIsBear  = (mlpProbs[2] > mlpProbs[0] && mlpProbs[2] > mlpProbs[1]);
   double mlpTopProb  = MathMax(mlpProbs[0], mlpProbs[2]);

   // --- MODE 2: DUAL-ENGINE SYNERGY (Both models agree on direction >= 0.52) ---
   if((lgbmIsBull && mlpIsBull && lgbmProbs[0] >= 0.52 && mlpProbs[0] >= 0.52) ||
      (lgbmIsBear && mlpIsBear && lgbmProbs[2] >= 0.52 && mlpProbs[2] >= 0.52))
   {
      int dir = (lgbmIsBull ? 0 : 2);
      double rawAvg = (lgbmProbs[dir] + mlpProbs[dir]) / 2.0;
      if(rule.active && rule.direction == dir)
         rawAvg = (rawAvg * 0.80) + (rule.confidence * 0.20);

      result.finalDirection     = dir;
      result.ensembleConfidence = MathMin(0.95, rawAvg * 1.20); // 1.20x Synergy Multiplier
      result.execute            = true;
      result.reason             = (dir == 0 ? "BULL DUAL-ENGINE SYNERGY (1.20x Boost)" : "BEAR DUAL-ENGINE SYNERGY (1.20x Boost)");
      return result;
   }

   // --- MODE 1A: LIGHTGBM SOLO TREND STRIKE (LGBM >= 0.58, MLP not hard opposing < 0.60) ---
   if((lgbmIsBull && lgbmProbs[0] >= 0.58 && mlpProbs[2] < 0.60) ||
      (lgbmIsBear && lgbmProbs[2] >= 0.58 && mlpProbs[0] < 0.60))
   {
      int dir = (lgbmIsBull ? 0 : 2);
      result.finalDirection     = dir;
      result.ensembleConfidence = (double)lgbmProbs[dir];
      result.execute            = true;
      result.reason             = (dir == 0 ? "LIGHTGBM SOLO BULL TREND STRIKE" : "LIGHTGBM SOLO BEAR TREND STRIKE");
      return result;
   }

   // --- MODE 1B: DEEP MLP SOLO PATTERN STRIKE (MLP >= 0.68, LGBM not hard opposing < 0.60) ---
   if((mlpIsBull && mlpProbs[0] >= 0.68 && lgbmProbs[2] < 0.60) ||
      (mlpIsBear && mlpProbs[2] >= 0.68 && lgbmProbs[0] < 0.60))
   {
      int dir = (mlpIsBull ? 0 : 2);
      result.finalDirection     = dir;
      result.ensembleConfidence = (double)mlpProbs[dir];
      result.execute            = true;
      result.reason             = (dir == 0 ? "DEEP MLP SOLO BULL PATTERN STRIKE" : "DEEP MLP SOLO BEAR PATTERN STRIKE");
      return result;
   }

   // --- MODE 3: REGIME-BASED ARBITRATION (When models are split) ---
   if(regime == REGIME_TREND)
   {
      // In Trending market: LightGBM is the master
      if((lgbmIsBull && lgbmProbs[0] >= 0.55) || (lgbmIsBear && lgbmProbs[2] >= 0.55))
      {
         int dir = (lgbmIsBull ? 0 : 2);
         result.finalDirection     = dir;
         result.ensembleConfidence = (double)lgbmProbs[dir];
         result.execute            = true;
         result.reason             = "TREND REGIME ARBITRATION (LightGBM Lead)";
         return result;
      }
   }
   else if(regime == REGIME_CHOP)
   {
      // In Choppy/Range market: Deep MLP + Rules are the master
      if((mlpIsBull && mlpProbs[0] >= 0.58) || (mlpIsBear && mlpProbs[2] >= 0.58))
      {
         int dir = (mlpIsBull ? 0 : 2);
         result.finalDirection     = dir;
         result.ensembleConfidence = (double)mlpProbs[dir];
         result.execute            = true;
         result.reason             = "CHOP REGIME ARBITRATION (MLP Reversion Lead)";
         return result;
      }
   }

   // Fallback: Weighted Average
   double wLgbm = 0.50, wMlp = 0.30, wRule = (rule.active ? 0.20 : 0.0);
   double totalW = wLgbm + wMlp + wRule;
   double wBull = (lgbmProbs[0] * wLgbm + mlpProbs[0] * wMlp + (rule.active && rule.direction == 0 ? rule.confidence * wRule : 0.0)) / totalW;
   double wBear = (lgbmProbs[2] * wLgbm + mlpProbs[2] * wMlp + (rule.active && rule.direction == 2 ? rule.confidence * wRule : 0.0)) / totalW;

   if(wBull >= 0.52 && wBull > wBear)
   {
      result.finalDirection     = 0;
      result.ensembleConfidence = wBull;
      result.execute            = true;
      result.reason             = "WEIGHTED CONSENSUS BULL";
   }
   else if(wBear >= 0.52 && wBear > wBull)
   {
      result.finalDirection     = 2;
      result.ensembleConfidence = wBear;
      result.execute            = true;
      result.reason             = "WEIGHTED CONSENSUS BEAR";
   }
   else
   {
      result.finalDirection     = 1;
      result.ensembleConfidence = MathMax(wBull, wBear);
      result.execute            = false;
      result.reason             = "STAND-ASIDE / INSUFFICIENT EDGE";
   }

   return result;
}

//+------------------------------------------------------------------+
//| Entry Strategies (On/Off)                                        |
//+------------------------------------------------------------------+
input group "=== Entry Strategies (On/Off) ==="
input bool   InpUseMomentumConfirm            = false;  // MOMENTUM_CONFIRM: N consecutive same-dir closes + ONNX lean (>0.50), fixed 0.01 lots
input int    InpMomentumConsecutiveBars       = 5;      // Consecutive same-direction M5 closes required to fire momentum
input double InpMomentumMinOnnxProb           = 0.52;   // Min same-direction ONNX prob (lean, NOT the 0.70 core bar)
input double InpMomentumConfirmRiskUSD        = 100.0;   // Fixed $ risk per momentum trade = 0.05 lots @ SL20 (matches core floor)
input bool   InpUseStrategy_Pullback          = false;  // Pullback entry strategy
input bool   InpUseStrategy_Scalping          = false;  // Scalping entry strategy
input bool   InpUseStrategy_Straddle          = false;  // Straddle entry strategy
input bool   InpUseStrategy_Donchian          = false;  // Donchian-channel breakout entry strategy
input bool   InpUseStrategy_VolumeBreakout    = false;  // Volume-breakout entry strategy
input bool   InpUseStrategy_VWAPPullback      = false;  // VWAP-pullback entry strategy
input bool   InpUseStrategy_MeanReversion     = false;  // Mean-reversion entry strategy
input bool   InpUseStrategy_Breakout          = false;  // Breakout entry strategy
input bool   InpUseStrategy_ExhaustionReentry = false;  // Exhaustion-reentry entry strategy

//+------------------------------------------------------------------+
//| ONNX Engine inputs (Ultimate 76 binary)                          |
//+------------------------------------------------------------------+
input group "=== ONNX Engine (42-Feature Quantum Alpha) ==="
input string InpGruModelPath      = "gold_master_ai.onnx";  // Model file (42-Feature Quantum Neural Engine)
input bool   InpUseSyntheticDxy   = true;    // Build DXY from ICE basket pairs (broker has no DXY)

//+------------------------------------------------------------------+
//| AI Settings (thresholds shared with the ONNX permission gate in  |
//| GE_EntryGates are declared THERE — EntryGates is the permission  |
//| authority and is included first. Only AI-exclusive settings are  |
//| declared here.                                                   |
//+------------------------------------------------------------------+
input group "=== AI Settings ==="
input double InpOnnxVetoProb        = 0.60;   // ONNX probability that vetoes the current direction
input int    InpOnnxEntryCooldown   = 90;     // Seconds to wait after an entry before the next one is allowed

//+------------------------------------------------------------------+
//| AI Provider (LLM API) — Groq primary, OpenRouter failover.       |
//| Endpoints are OpenAI-compatible chat/completions. Both URLs must |
//| be whitelisted in MT5: Tools->Options->Expert Advisors->WebRequest
//| before the first call. The 3s primary / 8s failover contract is  |
//| from Step 8.                                                     |
//+------------------------------------------------------------------+
input group "=== AI Provider (LLM API) ==="
input bool   InpUseAIIntelligence   = false;     // Master switch: enable live LLM calls
input string InpGroqAPIKey          = "";        // Groq API key (primary provider)
input string InpGroqModel           = "openai/gpt-oss-120b";     // Groq model name
input string InpGroqURL             = "https://api.groq.com/openai/v1/chat/completions"; // Groq endpoint
input string InpOpenRouterAPIKey    = "";        // OpenRouter API key (failover provider)
input string InpOpenRouterModel     = "google/gemma-4-31b-it";  // OpenRouter model name
input string InpOpenRouterURL       = "https://openrouter.ai/api/v1/chat/completions"; // OpenRouter endpoint
input int    InpAIPrimaryTimeoutMs  = 3000;      // Primary provider timeout (ms) — Step 8: 3s
input int    InpAIFailoverTimeoutMs = 8000;      // Failover provider timeout (ms) — Step 8: 8s
input int    InpAIMaxTokens         = 1024;      // Max response tokens per call
input double InpAITemperature       = 0.2;       // Sampling temperature

//+------------------------------------------------------------------+
//| Strategy-specific numeric parameters (Step 4 H-list)             |
//+------------------------------------------------------------------+
input group "=== Strategy Parameters ==="
input double InpExhaustionAtrBypass = 10.0;   // ATR in USD above which EXHAUSTION_REENTRY skips its normal guard
input double InpVwapRsiBuyLow       = 45.0;   // VWAP pullback: RSI low bound for BUY setups
input double InpVwapRsiBuyHigh      = 65.0;   // VWAP pullback: RSI high bound for BUY setups
input double InpVwapRsiSellLow      = 35.0;   // VWAP pullback: RSI low bound for SELL setups
input double InpVwapRsiSellHigh     = 55.0;   // VWAP pullback: RSI high bound for SELL setups

//+------------------------------------------------------------------+
//| PROMPT 1 — Intraday Trade Verification.                          |
//| Embedded verbatim from Step 8; draft placeholders refined to     |
//| UNIQUE tokens per field so StringReplace is unambiguous.         |
//| Parser may read ONLY: "allowed", "reason".                       |
//+------------------------------------------------------------------+
const string PROMPT_INTRADAY =
   "Gold (XAUUSD) Intraday Trade Verification.\r\n" +
   "Signal: [SIGNAL], Entry price: [ENTRY_PRICE].\r\n" +
   "ONNX model read: [ONNX_CLASS] at [ONNX_PROB]% probability, margin [ONNX_MARGIN].\r\n" +
   "Golden Ceiling (Resistance): [RESISTANCE] (distance: [RESISTANCE_DIST]).\r\n" +
   "Aqua Floor (Support): [SUPPORT] (distance: [SUPPORT_DIST]).\r\n" +
   "RSI(14): [RSI_VALUE], ATR(14): [ATR_VALUE].\r\n" +
   "Last 10 H1 closes: [CANDLE_HISTORY]\r\n" +
   "\r\n" +
   "As an elite intraday analyst, determine if the short-term trend (next 2-5 hours)\r\n" +
   "supports this [SIGNAL] trade, given that the ONNX model's own read is provided\r\n" +
   "above as reference context. Consider proximity to key levels, momentum, and\r\n" +
   "volatility. Respond strictly with a JSON object:\r\n" +
   "{\r\n" +
   "  \"allowed\": true or false,\r\n" +
   "  \"reason\": \"short 10-word explanation\"\r\n" +
   "}\r\n" +
   "Example: { \"allowed\": true, \"reason\": \"Bullish momentum above Aqua Floor, ONNX agrees\" }";

//+------------------------------------------------------------------+
//| PROMPT 2 — Active Position Management (HOLD/CLOSE only).         |
//| Embedded verbatim from Step 8.                                   |
//| Parser may read ONLY: "key_factors", "action", "reason".         |
//+------------------------------------------------------------------+
const string PROMPT_POSITION =
   "Gold (XAUUSD) active position management review.\r\n" +
   "TradeType/Strategy=[STRATEGY_TYPE], Type=[SIDE], EntryPrice=[ENTRY_PRICE], CurrentPrice=[CURRENT_PRICE],\r\n" +
   "CurrentSL=[CURRENT_SL], CurrentProfit=[CURRENT_PROFIT].\r\n" +
   "ONNX model read: [ONNX_CLASS] at [ONNX_PROB]% probability, margin [ONNX_MARGIN].\r\n" +
   "Recent 3 closed candles: [OHLC_HISTORY].\r\n" +
   "\r\n" +
   "Instructions:\r\n" +
   "- The Stop Loss is fixed at 6xATR and Take Profit at 8xATR. You cannot move, tighten,\r\n" +
   "  or widen the stop loss under any circumstance — the system does not accept stop\r\n" +
   "  adjustments from you. Your only decision is whether this position should be closed\r\n" +
   "  early or held.\r\n" +
   "- The position will be automatically closed after 4 hours regardless of your\r\n" +
   "  recommendation (time-decay). It will also close automatically if the ONNX model's\r\n" +
   "  own probability flips against this position while it's in profit (reversal-exit).\r\n" +
   "  Your HOLD/CLOSE recommendation only matters for exits before either of those\r\n" +
   "  triggers.\r\n" +
   "- If TradeType/Strategy is 'GE_SWING' (long-horizon trade), be patient — do not\r\n" +
   "  recommend closing for minor pullbacks (3-5 USD retracements) if the macro H1/Daily\r\n" +
   "  structure is still intact. Only recommend CLOSE if opposite trend structure is\r\n" +
   "  clearly confirmed.\r\n" +
   "- For all other strategy types, recommend CLOSE promptly if momentum has clearly and\r\n" +
   "  meaningfully reversed against the position; otherwise HOLD.\r\n" +
   "\r\n" +
   "Respond strictly with a JSON object:\r\n" +
   "{\r\n" +
   "  \"key_factors\": [\"short factor 1\", \"short factor 2\"],\r\n" +
   "  \"action\": \"HOLD\" or \"CLOSE\",\r\n" +
   "  \"reason\": \"short 10-word explanation\"\r\n" +
   "}\r\n" +
   "Example: { \"key_factors\": [\"H1 structure broken\", \"ONNX flipped bearish\"], \"action\": \"CLOSE\", \"reason\": \"Bearish reversal confirmed on H1\" }";

//+------------------------------------------------------------------+
//| PROMPT 3 — Setup Analysis & Discretionary Entry (Master Prompt). |
//| Embedded verbatim from Step 8; draft placeholders refined to     |
//| UNIQUE tokens per field so StringReplace is unambiguous.         |
//| Parser may read ONLY: "key_factors", "decision", "conviction",   |
//| "regime", "strategy", "reason".                                  |
//+------------------------------------------------------------------+
const string PROMPT_SETUP =
   "Gold (XAUUSD) setup analysis. Current price=[CURRENT_PRICE]. Active Session: [SESSIONS].\r\n" +
   "Account Capital: Balance=[BALANCE], Equity=[EQUITY], Free Margin=[FREE_MARGIN],\r\n" +
   "Margin Level=[MARGIN_LEVEL]%.\r\n" +
   "\r\n" +
   "ONNX model read (reference — you do NOT need to match this exactly, but you should\r\n" +
   "know it): [ONNX_CLASS] at [ONNX_PROB]% probability, margin [ONNX_MARGIN]. Note: regardless of\r\n" +
   "your decision below, the system will only execute this trade if it agrees in\r\n" +
   "direction with the current ONNX read. A well-reasoned setup that disagrees with ONNX\r\n" +
   "will not be placed — factor this into whether it's worth recommending at all.\r\n" +
   "\r\n" +
   "GNN Line Distances: [GNN_DISTANCES]. EMA Fan Trend Details: [EMA_FAN_DETAILS].\r\n" +
   "Technical Signals: Macro Trend is [MACRO_TREND_STATUS], Intraday VWAP is [VWAP_STATUS], RSI Status:\r\n" +
   "[RSI_STATUS], Spread Status: [SPREAD_STATUS]. Daily Range Analysis: [DAILY_RANGE_ANALYSIS].\r\n" +
   "Multi-Timeframe Trend [MTF_CONFLUENCE]. Volatility opens: [VOL_OPENS_STATUS]. Trend Direction:\r\n" +
   "[TREND_DIRECTION_STATUS].\r\n" +
   "Indicators: ADX=[ADX], ATR=[ATR], RSI=[RSI], EMA50=[EMA50], EMA200=[EMA200],\r\n" +
   "EMA9=[EMA9], VWAP=[VWAP], VolSMA10=[VOLSMA10], VolSMA20=[VOLSMA20], Spread=[SPREAD].\r\n" +
   "Upcoming High-Impact News today: [NEWS_LIST].\r\n" +
   "Price History (Active Timeframe): [M5_OHLC].\r\n" +
   "Macro Price History (Higher Timeframe): [H1H4_OHLC].\r\n" +
   "Candle Patterns (Last 3 Bars): [CANDLE_PATTERNS].\r\n" +
   "Recent closed trades history: [TRADE_HISTORY].\r\n" +
   "ICT Market Structure (Order Blocks & Fair Value Gaps): [SMC_DETAILS].\r\n" +
   "\r\n" +
   "As an Elite Discretionary Quant Trader, analyze the market context holistically using\r\n" +
   "Smart Money Concepts (SMC), raw Price Action, and GNN boundaries. Do not act like a\r\n" +
   "rigid indicator-matching script. Indicators are secondary confluence; your primary\r\n" +
   "guidance is Market Structure (BOS/ChoCh), Wick Rejections, and Liquidity Sweeps.\r\n" +
   "\r\n" +
   "Note: every trade uses a fixed Stop Loss (6xATR) and fixed Take Profit (8xATR),\r\n" +
   "applied automatically. You do not set the stop loss or take profit — your job is\r\n" +
   "only to decide whether to enter, in which direction, and with how much conviction.\r\n" +
   "Do not attempt to reason about custom SL/TP placement; it will not be used.\r\n" +
   "\r\n" +
   "Instructions:\r\n" +
   "1. DYNAMIC STRUCTURAL ANALYSIS: Read the structural phase, order blocks, FVG gaps,\r\n" +
   "   and GNN boundaries. You have full freedom to trade anywhere on the chart.\r\n" +
   "2. FLEXIBLE STRATEGY PLAY: Range Reversals at GNN lines, Trend Pullbacks at\r\n" +
   "   EMA/VWAP levels, or Volatility Breakouts out of consolidations — evaluate every\r\n" +
   "   setup on its own dynamic statistical edge.\r\n" +
   "3. PATIENCE & CONVICTION CALIBRATION: A master trader only takes setups with a clear\r\n" +
   "   edge. Issue 'HOLD' when the market is in a low-volatility squeeze, has high\r\n" +
   "   spread, or shows choppy overlapping price action with no clear directional bias.\r\n" +
   "   Calibrate your conviction score using these anchors:\r\n" +
   "   - 85-100: Textbook setup — multiple confirming signals (structure + ONNX\r\n" +
   "     agreement + clean price action), no meaningful conflicting evidence;\r\n" +
   "     would risk maximum size on this alone.\r\n" +
   "   - 60-84: Solid setup with at least one caveat or partial confirmation;\r\n" +
   "     reasonable size with full confidence.\r\n" +
   "   - 35-59: Speculative — some merit but real uncertainty; would only take\r\n" +
   "     with reduced size or strong external confirmation.\r\n" +
   "   - 0-34: Do not trade — insufficient edge or active conflicting signals.\r\n" +
   "4. CONFLICTING BIAS PROTECTION: If the EMA Fan shows a strong uptrend (Angle > 45)\r\n" +
   "   but the macro trend is bearish, look for high-probability pullback reversals or\r\n" +
   "   breakout entries rather than forcing a trade.\r\n" +
   "5. OVER-EXTENSION / TREND-EXHAUSTION RULE: If price has run far beyond\r\n" +
   "   EMA200/VWAP (severely over-extended, RSI overbought/oversold, long wick\r\n" +
   "   rejection on the last candle), DO NOT chase the move. Prefer SELL at exhaustion\r\n" +
   "   tops and BUY at exhaustion bottoms, OR HOLD until a pullback.\r\n" +
   "6. OBJECTIVE CAPITAL PRESERVATION: If recent trades show consecutive losses, raise\r\n" +
   "   your conviction threshold and only recommend the highest-probability setups.\r\n" +
   "7. STRICT ONE-POSITION POLICY: The system enforces a maximum of [MAX_POSITIONS]\r\n" +
   "   concurrent position(s). Your decision is for the next available position slot only.\r\n" +
   "8. LONG-TERM SWING TRADES: Favor swing-style entries when there is a clear,\r\n" +
   "   established macro trend on the higher timeframe. Note: the exit (6xATR/8xATR,\r\n" +
   "   4h time-decay, reversal-exit) is fixed regardless of horizon — factor this into\r\n" +
   "   whether a swing-style entry still makes sense given the fixed exit.\r\n" +
   "9. REGIME-SWITCHING STRATEGY:\r\n" +
   "   (a) RANGE/Reversion mode (ADX<25 or ONNX model reads RANGING-equivalent low\r\n" +
   "       confidence): trade BOTH directions freely, SELL at resistance ceilings, BUY\r\n" +
   "       at support floors, with 35%+ wick-rejection candle-close confirmation.\r\n" +
   "   (b) TREND/Breakout mode (ADX>=25): keep the macro direction lock — but note the\r\n" +
   "       system's own ONNX-agreement check enforces this at the code level regardless\r\n" +
   "       of what you recommend, so use this as your own reasoning discipline, not a\r\n" +
   "       hard external rule you must separately enforce.\r\n" +
   "   Set 'regime' accordingly: 'BREAKOUT' or 'REVERSION'.\r\n" +
   "10. EXTREME RSI COUNTER-TREND OVERRIDE: If RSI(M5) is severely overbought (>75) at\r\n" +
   "    a resistance test, a SELL pullback is authorized even in a bullish trend, and\r\n" +
   "    vice versa for oversold at support. High-volume/volatility breakout expansions\r\n" +
   "    block such counter-trend fades.\r\n" +
   "\r\n" +
   "Respond strictly with a JSON object:\r\n" +
   "{\r\n" +
   "  \"key_factors\": [\"short factor 1\", \"short factor 2\", \"short factor 3\"],\r\n" +
   "  \"decision\": \"BUY\" or \"SELL\" or \"HOLD\",\r\n" +
   "  \"conviction\": integer 0-100,\r\n" +
   "  \"regime\": \"BREAKOUT\" or \"REVERSION\",\r\n" +
   "  \"strategy\": \"BREAKOUT\" or \"MEAN_REVERSION\" or \"PULLBACK\" or \"STRADDLE\" or\r\n" +
   "    \"SCALPING\" or \"DONCHIAN_BREAKOUT\" or \"VOLUME_BREAKOUT\" or \"VWAP_PULLBACK\" or\r\n" +
   "    \"EXHAUSTION_REENTRY\",\r\n" +
   "  \"reason\": \"short 10 words explaining the decision\"\r\n" +
   "}";

//+------------------------------------------------------------------+
//| JSON helpers — reused project pattern (legacy ExtractJSONValue)  |
//| extended with an array extractor for "key_factors".              |
//+------------------------------------------------------------------+
string ExtractJSONValue(const string json, const string key)
{
   string searchKey = "\"" + key + "\"";
   int startIdx = StringFind(json, searchKey);
   if(startIdx < 0)
   {
      searchKey = "'" + key + "'";
      startIdx = StringFind(json, searchKey);
   }
   if(startIdx < 0) return "";

   int colonIdx = StringFind(json, ":", startIdx + StringLen(searchKey));
   if(colonIdx < 0) return "";

   int valStart = colonIdx + 1;
   while(valStart < StringLen(json))
   {
      string ch = StringSubstr(json, valStart, 1);
      if(ch == " " || ch == "\t" || ch == "\r" || ch == "\n")
         valStart++;
      else
         break;
   }

   string firstCh = StringSubstr(json, valStart, 1);
   if(firstCh == "\"" || firstCh == "'")
   {
      string quote = firstCh;
      valStart++;
      int valEnd = StringFind(json, quote, valStart);
      if(valEnd < 0) return "";
      return StringSubstr(json, valStart, valEnd - valStart);
   }

   int valEnd = valStart;
   while(valEnd < StringLen(json))
   {
      string ch = StringSubstr(json, valEnd, 1);
      if(ch == "," || ch == "}" || ch == "\r" || ch == "\n" || ch == "]")
         break;
      valEnd++;
   }
   if(valEnd > valStart)
      return StringSubstr(json, valStart, valEnd - valStart);
   return "";
}

//+------------------------------------------------------------------+
//| ExtractJSONArray — pulls a string array like "key_factors" into  |
//| an output array; returns element count (0 if absent/empty).      |
//+------------------------------------------------------------------+
int ExtractJSONArray(const string json, const string key, string &out[])
{
   ArrayResize(out, 0);
   string searchKey = "\"" + key + "\"";
   int startIdx = StringFind(json, searchKey);
   if(startIdx < 0)
   {
      searchKey = "'" + key + "'";
      startIdx = StringFind(json, searchKey);
   }
   if(startIdx < 0) return 0;

   int colonIdx = StringFind(json, ":", startIdx + StringLen(searchKey));
   if(colonIdx < 0) return 0;

   int openIdx = StringFind(json, "[", colonIdx);
   int closeIdx = StringFind(json, "]", colonIdx);
   if(openIdx < 0 || closeIdx < 0 || closeIdx < openIdx) return 0;

   string inner = StringSubstr(json, openIdx + 1, closeIdx - openIdx - 1);
   int pos = 0;
   while(pos < StringLen(inner))
   {
      int q1 = StringFind(inner, "\"", pos);
      if(q1 < 0) break;
      int q2 = StringFind(inner, "\"", q1 + 1);
      if(q2 < 0) break;
      string item = StringSubstr(inner, q1 + 1, q2 - q1 - 1);
      int n = ArraySize(out);
      ArrayResize(out, n + 1);
      out[n] = item;
      pos = q2 + 1;
   }
   return ArraySize(out);
}

//+------------------------------------------------------------------+
//| STEP 8 ADDENDUM: malformed/fenced JSON fail-safe helpers.        |
//+------------------------------------------------------------------+
int StringFindLast(const string text, const string sub)
{
   int pos = -1;
   int p = 0;
   while(p < StringLen(text))
   {
      int idx = StringFind(text, sub, p);
      if(idx < 0) break;
      pos = idx;
      p = idx + 1;
   }
   return pos;
}

//+------------------------------------------------------------------+
//| SanitizeAIResponse — strip markdown fences (```json ... ```) and |
//| stray text before/after the JSON object. Extracts the single     |
//| balanced {...} block. Returns "" if no JSON object is present.   |
//+------------------------------------------------------------------+
string SanitizeAIResponse(const string raw)
{
   string out = raw;
   StringTrimLeft(out);
   StringTrimRight(out);
   int firstBrace = StringFind(out, "{");
   int lastBrace  = StringFindLast(out, "}");
   if(firstBrace >= 0 && lastBrace > firstBrace)
      return StringSubstr(out, firstBrace, lastBrace - firstBrace + 1);
   return "";
}

//+------------------------------------------------------------------+
//| LogAIParseFailure — distinct marker so malformed responses are   |
//| countable separately from a true API timeout.                    |
//+------------------------------------------------------------------+
void LogAIParseFailure(const string promptName, const string responseText)
{
   Print("[AI Parse Failure] ", promptName, " — malformed or missing required fields. Response: ", responseText);
}

//+------------------------------------------------------------------+
//| PROMPT 1 RESULT — parser reads ONLY "allowed" + "reason".        |
//| Fence-stripped first. valid=false => allowed=false (fail-safe,   |
//| identical to a timeout); caller logs [AI Parse Failure].         |
//+------------------------------------------------------------------+
struct SIntradayVerdict
{
   bool   allowed;
   string reason;
   bool   valid;
};

SIntradayVerdict ParseIntradayVerdict(const string responseText)
{
   SIntradayVerdict v;
   v.valid    = false;
   v.allowed  = false;
   v.reason   = "";
   string clean = SanitizeAIResponse(responseText);
   if(clean == "")
      return v;
   string raw = ExtractJSONValue(clean, "allowed");
   v.allowed = (StringFind(raw, "true") >= 0);
   v.reason  = ExtractJSONValue(clean, "reason");
   v.valid   = (raw != "" || v.reason != "");
   return v;
}

//+------------------------------------------------------------------+
//| PROMPT 2 RESULT — parser reads ONLY "key_factors", "action",     |
//| "reason". No SL/TP fields exist in the prompt, so none are read. |
//| valid=false => action defaults "HOLD" (never CLOSE on garbage).  |
//+------------------------------------------------------------------+
struct SPositionVerdict
{
   string action;        // HOLD / CLOSE
   string reason;
   string key_factors[];
   bool   valid;
};

SPositionVerdict ParsePositionVerdict(const string responseText)
{
   SPositionVerdict v;
   v.valid  = false;
   v.action = "HOLD";
   v.reason = "";
   string clean = SanitizeAIResponse(responseText);
   if(clean == "")
      return v;
   v.action = ExtractJSONValue(clean, "action");
   v.reason = ExtractJSONValue(clean, "reason");
   ExtractJSONArray(clean, "key_factors", v.key_factors);
   v.valid = (v.action == "HOLD" || v.action == "CLOSE");
   return v;
}

//+------------------------------------------------------------------+
//| PROMPT 3 RESULT — parser reads ONLY "key_factors", "decision",   |
//| "conviction", "regime", "strategy", "reason".                    |
//| Deliberately excluded: expected_hold_bars, stop_loss_price,      |
//| take_profit_price, horizon (confirmed dead, not requested).      |
//| valid=false => conviction forced 0, decision "HOLD", caller sets |
//| aiActive=false + logs [AI Parse Failure] — identical to timeout. |
//+------------------------------------------------------------------+
struct SSetupVerdict
{
   string decision;      // BUY / SELL / HOLD
   int    conviction;    // 0-100
   string regime;        // BREAKOUT / REVERSION
   string strategy;      // one of the 9 strategy strings
   string reason;
   string key_factors[];
   bool   valid;
};

SSetupVerdict ParseSetupVerdict(const string responseText)
{
   SSetupVerdict v;
   v.valid      = false;
   v.decision   = "HOLD";
   v.conviction = 0;
   v.regime     = "";
   v.strategy   = "";
   v.reason     = "";
   string clean = SanitizeAIResponse(responseText);
   if(clean == "")
      return v;
   v.decision   = ExtractJSONValue(clean, "decision");
   v.conviction = (int)StringToInteger(ExtractJSONValue(clean, "conviction"));
   v.regime     = ExtractJSONValue(clean, "regime");
   v.strategy   = ExtractJSONValue(clean, "strategy");
   v.reason     = ExtractJSONValue(clean, "reason");
   ExtractJSONArray(clean, "key_factors", v.key_factors);
   v.valid = (v.decision == "BUY" || v.decision == "SELL" || v.decision == "HOLD") &&
             (v.strategy != "");
   return v;
}

//+------------------------------------------------------------------+
//| PROMPT 1 builder — substitute unique tokens with live values.    |
//+------------------------------------------------------------------+
string BuildPrompt_Intraday(const string signal, const string entryPrice,
                            const string onnxClass, const string onnxProb, const string onnxMargin,
                            const string resistance, const string resDist,
                            const string support, const string supDist,
                            const string rsi, const string atr,
                            const string candleHistory)
{
   string p = PROMPT_INTRADAY;
   StringReplace(p, "[SIGNAL]", signal);
   StringReplace(p, "[ENTRY_PRICE]", entryPrice);
   StringReplace(p, "[ONNX_CLASS]", onnxClass);
   StringReplace(p, "[ONNX_PROB]", onnxProb);
   StringReplace(p, "[ONNX_MARGIN]", onnxMargin);
   StringReplace(p, "[RESISTANCE]", resistance);
   StringReplace(p, "[RESISTANCE_DIST]", resDist);
   StringReplace(p, "[SUPPORT]", support);
   StringReplace(p, "[SUPPORT_DIST]", supDist);
   StringReplace(p, "[RSI_VALUE]", rsi);
   StringReplace(p, "[ATR_VALUE]", atr);
   StringReplace(p, "[CANDLE_HISTORY]", candleHistory);
   return p;
}

//+------------------------------------------------------------------+
//| PROMPT 2 builder.                                                |
//+------------------------------------------------------------------+
string BuildPrompt_Position(const string strategyType, const string side,
                            const string entryPrice, const string currentPrice,
                            const string currentSL, const string currentProfit,
                            const string onnxClass, const string onnxProb, const string onnxMargin,
                            const string ohlcHistory)
{
   string p = PROMPT_POSITION;
   StringReplace(p, "[STRATEGY_TYPE]", strategyType);
   StringReplace(p, "[SIDE]", side);
   StringReplace(p, "[ENTRY_PRICE]", entryPrice);
   StringReplace(p, "[CURRENT_PRICE]", currentPrice);
   StringReplace(p, "[CURRENT_SL]", currentSL);
   StringReplace(p, "[CURRENT_PROFIT]", currentProfit);
   StringReplace(p, "[ONNX_CLASS]", onnxClass);
   StringReplace(p, "[ONNX_PROB]", onnxProb);
   StringReplace(p, "[ONNX_MARGIN]", onnxMargin);
   StringReplace(p, "[OHLC_HISTORY]", ohlcHistory);
   return p;
}

//+------------------------------------------------------------------+
//| PROMPT 3 builder. Long signature matches the many context fields.|
//+------------------------------------------------------------------+
string BuildPrompt_Setup(const string currentPrice, const string sessions,
                         const string balance, const string equity,
                         const string freeMargin, const string marginLevel,
                         const string onnxClass, const string onnxProb, const string onnxMargin,
                         const string gnnDistances, const string emaFanDetails,
                         const string macroTrendStatus, const string vwapStatus,
                         const string rsiStatus, const string spreadStatus,
                         const string dailyRangeAnalysis, const string mtfConfluence,
                         const string volOpensStatus, const string trendDirectionStatus,
                         const string adx, const string atr, const string rsi,
                         const string ema50, const string ema200, const string ema9,
                         const string vwap, const string volSMA10, const string volSMA20,
                         const string spread, const string newsList,
                         const string m5Ohlc, const string h1h4Ohlc,
                         const string candlePatterns, const string tradeHistory,
                         const string smcDetails, const string maxPositions)
{
   string p = PROMPT_SETUP;
   StringReplace(p, "[CURRENT_PRICE]", currentPrice);
   StringReplace(p, "[SESSIONS]", sessions);
   StringReplace(p, "[BALANCE]", balance);
   StringReplace(p, "[EQUITY]", equity);
   StringReplace(p, "[FREE_MARGIN]", freeMargin);
   StringReplace(p, "[MARGIN_LEVEL]", marginLevel);
   StringReplace(p, "[ONNX_CLASS]", onnxClass);
   StringReplace(p, "[ONNX_PROB]", onnxProb);
   StringReplace(p, "[ONNX_MARGIN]", onnxMargin);
   StringReplace(p, "[GNN_DISTANCES]", gnnDistances);
   StringReplace(p, "[EMA_FAN_DETAILS]", emaFanDetails);
   StringReplace(p, "[MACRO_TREND_STATUS]", macroTrendStatus);
   StringReplace(p, "[VWAP_STATUS]", vwapStatus);
   StringReplace(p, "[RSI_STATUS]", rsiStatus);
   StringReplace(p, "[SPREAD_STATUS]", spreadStatus);
   StringReplace(p, "[DAILY_RANGE_ANALYSIS]", dailyRangeAnalysis);
   StringReplace(p, "[MTF_CONFLUENCE]", mtfConfluence);
   StringReplace(p, "[VOL_OPENS_STATUS]", volOpensStatus);
   StringReplace(p, "[TREND_DIRECTION_STATUS]", trendDirectionStatus);
   StringReplace(p, "[ADX]", adx);
   StringReplace(p, "[ATR]", atr);
   StringReplace(p, "[RSI]", rsi);
   StringReplace(p, "[EMA50]", ema50);
   StringReplace(p, "[EMA200]", ema200);
   StringReplace(p, "[EMA9]", ema9);
   StringReplace(p, "[VWAP]", vwap);
   StringReplace(p, "[VOLSMA10]", volSMA10);
   StringReplace(p, "[VOLSMA20]", volSMA20);
   StringReplace(p, "[SPREAD]", spread);
   StringReplace(p, "[NEWS_LIST]", newsList);
   StringReplace(p, "[M5_OHLC]", m5Ohlc);
   StringReplace(p, "[H1H4_OHLC]", h1h4Ohlc);
   StringReplace(p, "[CANDLE_PATTERNS]", candlePatterns);
   StringReplace(p, "[TRADE_HISTORY]", tradeHistory);
   StringReplace(p, "[SMC_DETAILS]", smcDetails);
   StringReplace(p, "[MAX_POSITIONS]", maxPositions);
   return p;
}

//+------------------------------------------------------------------+
//| GRU 76-feature engine (Ultimate 76 binary).                      |
//| Faithful port of the legacy CGRUFilter restricted to the 76-     |
//| feature contract (RANGE pinned 0). Always feeds PERIOD_M5 bars   |
//| (96-bar window = 8h context) regardless of the chart timeframe.  |
//+------------------------------------------------------------------+
#define GRU_SEQ_LEN        96
#define GRU_MAX_FEATURES   76
#define GRU_M5_WARMUP      7000
#define GRU_DXY_WARMUP     3000
#define GRU_H1_WARMUP      1200
#define GRU_H4_WARMUP      600
#define GRU_D1_WARMUP      400
#define GRU_WIN_SLOPE      5
#define GRU_CORR_WINDOW    48

void GRU_RollMean(const double &x[], int n, int w, double &out[])
{
   double sum = 0.0;
   for(int i = 0; i < n; i++)
   {
      sum += x[i];
      if(i >= w) sum -= x[i - w];
      out[i] = (i >= w - 1) ? sum / w : 0.0;
   }
}

void GRU_RollStd(const double &x[], int n, int w, double &out[])
{
   double sum = 0.0, sq = 0.0;
   for(int i = 0; i < n; i++)
   {
      sum += x[i]; sq += x[i] * x[i];
      if(i >= w) { sum -= x[i - w]; sq -= x[i - w] * x[i - w]; }
      if(i >= w - 1)
      {
         double m1 = sum / w, m2 = sq / w;
         out[i] = MathSqrt(MathMax(m2 - m1 * m1, 0.0));
      }
      else out[i] = 0.0;
   }
}

void GRU_Zscore(const double &x[], int n, int w, double &out[])
{
   double mean[], sd[];
   ArrayResize(mean, n);
   ArrayResize(sd, n);
   GRU_RollMean(x, n, w, mean);
   GRU_RollStd(x, n, w, sd);
   for(int i = 0; i < n; i++)
      out[i] = (sd[i] > 0.0) ? (x[i] - mean[i]) / sd[i] : 0.0;
}

void GRU_EMA(const double &x[], int n, int span, double &out[])
{
   double alpha = 2.0 / (span + 1.0);
   out[0] = x[0];
   for(int i = 1; i < n; i++)
      out[i] = out[i - 1] + alpha * (x[i] - out[i - 1]);
}

// Multi-timeframe derived features from a close series: zclose(20), ema_slope, dist_ema
// (mirror training features_advanced._mtf_block)
void MTFDerived(const double &cl[], int n, double &zc[], double &es[], double &de[])
{
   if(n <= 0) return;
   double mean[], sd[], ema[];
   ArrayResize(mean, n); ArrayResize(sd, n); ArrayResize(ema, n);
   GRU_RollMean(cl, n, 20, mean);
   GRU_RollStd(cl, n, 20, sd);
   GRU_EMA(cl, n, 20, ema);
   for(int i = 0; i < n; i++)
   {
      zc[i] = (sd[i] > 1e-8) ? (cl[i] - mean[i]) / sd[i] : 0.0;
      double e_prev = (i >= 10) ? ema[i - 10] : ema[0];
      es[i] = (ema[i] * 1e-3 > 1e-12) ? (ema[i] - e_prev) / (ema[i] * 1e-3) : 0.0;
      de[i] = (ema[i] * 1e-3 > 1e-12) ? (cl[i] - ema[i]) / (ema[i] * 1e-3) : 0.0;
   }
}

void GRU_Slope(const double &x[], int n, double &out[])
{
   int w = GRU_WIN_SLOPE;
   double denom = w * (w * w - 1.0) / 12.0;
   double sx = 0.0, sy = 0.0, sxy = 0.0;
   for(int i = 0; i < n; i++)
   {
      sx += i; sy += x[i]; sxy += x[i] * i;
      if(i >= w)
      {
         sx -= (i - w); sy -= x[i - w]; sxy -= x[i - w] * (i - w);
      }
      if(i >= w - 1)
         out[i] = (sxy - sy * sx / w) / denom;
      else out[i] = 0.0;
   }
}

void GRU_RSI(const double &x[], int n, int period, double &out[])
{
   double alpha = 2.0 / (period + 1.0);
   double ag = 0.0, al = 0.0;
   bool started = false;
   for(int i = 0; i < n; i++)
   {
      if(i == 0) { out[i] = 0.0; continue; }
      double d = x[i] - x[i - 1];
      double g = MathMax(d, 0.0), l = MathMax(-d, 0.0);
      if(!started) { ag = g; al = l; started = true; }
      else { ag += alpha * (g - ag); al += alpha * (l - al); }
      if(al > 0.0) out[i] = 100.0 - 100.0 / (1.0 + ag / al);
      else         out[i] = (ag > 0.0) ? 100.0 : 0.0;
   }
}

void GRU_TR(const double &h[], const double &l[], const double &c[], int n, double &tr[])
{
   tr[0] = h[0] - l[0];
   for(int i = 1; i < n; i++)
   {
      double a = h[i] - l[i];
      double b = MathAbs(h[i] - c[i - 1]);
      double d = MathAbs(l[i] - c[i - 1]);
      tr[i] = MathMax(a, MathMax(b, d));
   }
}

// Rolling sum of last w elements (for choppiness TR sum)
void GRU_RollSum(const double &x[], int n, int w, double &out[])
{
   double sum = 0.0;
   for(int i = 0; i < n; i++)
   {
      sum += x[i];
      if(i >= w) sum -= x[i - w];
      out[i] = (i >= w - 1) ? sum : 0.0;
   }
}

// Wilder's ADX (matches training features_advanced._adx)
void GRU_ADX(const double &h[], const double &l[], const double &c[], int n, int period, double &out[])
{
   if(n < period + 1) { for(int i = 0; i < n; i++) out[i] = 0.0; return; }
   double tr[], pdm[], mdm[];
   ArrayResize(tr, n); ArrayResize(pdm, n); ArrayResize(mdm, n);
   tr[0] = h[0] - l[0]; pdm[0] = 0.0; mdm[0] = 0.0;
   for(int i = 1; i < n; i++)
   {
      double pc = c[i - 1];
      tr[i] = MathMax(h[i] - l[i], MathMax(MathAbs(h[i] - pc), MathAbs(l[i] - pc)));
      double up = h[i] - h[i - 1];
      double dn = l[i - 1] - l[i];
      pdm[i] = (up > dn && up > 0.0) ? up : 0.0;
      mdm[i] = (dn > up && dn > 0.0) ? dn : 0.0;
   }
   double a = 1.0 / (double)period;
   double atr = 0.0, p = 0.0, m = 0.0;
   for(int i = 1; i <= period; i++) { atr += tr[i]; p += pdm[i]; m += mdm[i]; }
   atr /= (double)period; p /= (double)period; m /= (double)period;
   double dxarr[];
   ArrayResize(dxarr, n);
   for(int i = period; i < n; i++)
   {
      atr = (atr * (period - 1) + tr[i]) / (double)period;
      p   = (p * (period - 1) + pdm[i]) / (double)period;
      m   = (m * (period - 1) + mdm[i]) / (double)period;
      double pdi = 100.0 * p / atr;
      double mdi = 100.0 * m / atr;
      dxarr[i] = 100.0 * MathAbs(pdi - mdi) / MathMax(pdi + mdi, 1e-8);
   }
   // ADX seed = mean of first `period` DX values
   double s = 0.0; int cnt = 0;
   for(int k = period; k < period * 2 && k < n; k++) { s += dxarr[k]; cnt++; }
   double adxv = (cnt > 0) ? s / (double)cnt : dxarr[period];
   for(int i = 0; i < n; i++) out[i] = 0.0;
   out[period] = adxv;
   for(int i = period + 1; i < n; i++)
   {
      adxv = (adxv * (period - 1) + dxarr[i]) / (double)period;
      out[i] = adxv;
   }
}

// Rolling sample skewness & (excess) kurtosis over window w
void GRU_RollSkewKurt(const double &x[], int n, int w, double &sk[], double &ku[])
{
   for(int i = 0; i < n; i++)
   {
      if(i < w - 1) { sk[i] = 0.0; ku[i] = 0.0; continue; }
      double s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0;
      for(int k = i - w + 1; k <= i; k++)
      {
         double v = x[k];
         s1 += v; s2 += v * v; s3 += v * v * v; s4 += v * v * v * v;
      }
      double m1 = s1 / (double)w, m2 = s2 / (double)w, m3 = s3 / (double)w, m4 = s4 / (double)w;
      double var = m2 - m1 * m1;
      if(var <= 1e-12) { sk[i] = 0.0; ku[i] = 0.0; continue; }
      double sd = MathSqrt(var);
      sk[i] = (m3 - 3.0 * m1 * m2 + 2.0 * m1 * m1 * m1) / (sd * sd * sd);
      ku[i] = (m4 - 4.0 * m1 * m3 + 6.0 * m1 * m1 * m2 - 3.0 * m1 * m1 * m1 * m1) / (sd * sd * sd * sd) - 3.0;
   }
}

double GRU_CorrWin(const double &x[], const double &y[], int i, int w)
{
   if(i < w - 1) return 0.0;
   double sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0;
   for(int k = i - w + 1; k <= i; k++)
   {
      double xv = x[k], yv = y[k];
      if(xv != xv || yv != yv) return 0.0;
      sx += xv; sy += yv;
      sxx += xv * xv; syy += yv * yv; sxy += xv * yv;
   }
   double n = (double)w;
   double cov = sxy - sx * sy / n;
   double vx = sxx - sx * sx / n;
   double vy = syy - sy * sy / n;
   if(vx <= 0.0 || vy <= 0.0) return 0.0;
   return cov / MathSqrt(vx * vy);
}

void GRU_SwingFractals(const double &h[], const double &l[], int n, int w,
                       bool &sh[], bool &sl[])
{
   for(int i = 0; i < n; i++) { sh[i] = false; sl[i] = false; }
   for(int i = w; i < n - w; i++)
   {
      double mh = -DBL_MAX, ml = DBL_MAX;
      for(int k = i - w; k < i; k++) { if(h[k] > mh) mh = h[k]; if(l[k] < ml) ml = l[k]; }
      bool sh_ok = (h[i] > mh);
      bool sl_ok = (l[i] < ml);
      mh = -DBL_MAX; ml = DBL_MAX;
      for(int k = i + 1; k < i + w + 1; k++) { if(h[k] > mh) mh = h[k]; if(l[k] < ml) ml = l[k]; }
      if(sh_ok && h[i] >= mh) sh[i] = true;
      if(sl_ok && l[i] <= ml) sl[i] = true;
   }
}

void GRU_MSS(const double &h[], const double &l[], const double &c[], int n,
             double &out[])
{
   bool sh[], sl[];
   ArrayResize(sh, n); ArrayResize(sl, n);
   GRU_SwingFractals(h, l, n, 2, sh, sl);
   double lastSh = -1.0, lastSl = DBL_MAX;
   int lastShBar = -1, lastSlBar = -1;
   for(int i = 0; i < n; i++)
   {
      if(sh[i]) { lastSh = h[i]; lastShBar = i; }
      if(sl[i]) { lastSl = l[i]; lastSlBar = i; }
      if(lastShBar > lastSlBar && c[i] > lastSh)
      {
         out[i] = 1.0;
         lastSh = -1.0; lastShBar = -1;
      }
      else if(lastSlBar > lastShBar && c[i] < lastSl)
      {
         out[i] = -1.0;
         lastSl = DBL_MAX; lastSlBar = -1;
      }
      else
         out[i] = 0.0;
   }
}

void GRU_OrderBlocks(const double &o[], const double &h[], const double &l[],
                     const double &c[], const double &atr[], int n, int w,
                     double &dbull[], double &dbear[])
{
   int dirn[];
   ArrayResize(dirn, n);
   dirn[0] = 0;
   for(int i = 1; i < n; i++) dirn[i] = (c[i] > c[i - 1]) ? 1 : ((c[i] < c[i - 1]) ? -1 : 0);
   double obBull = 0.0, obBear = 0.0;
   bool haveBull = false, haveBear = false;
   for(int i = 0; i < n; i++)
   {
      if(i >= w)
      {
         bool downImp = true, upImp = true;
         for(int k = i - w + 1; k <= i; k++)
         {
            if(dirn[k] > 0) downImp = false;
            if(dirn[k] < 0) upImp = false;
         }
         if(downImp && i + 1 < n && c[i + 1] > c[i]) { obBull = l[i]; haveBull = true; }
         if(upImp   && i + 1 < n && c[i + 1] < c[i]) { obBear = h[i]; haveBear = true; }
      }
      double at = (atr[i] > 0.0) ? atr[i] : 0.0;
      dbull[i] = (haveBull && at > 0.0) ? (c[i] - obBull) / at : 0.0;
      dbear[i] = (haveBear && at > 0.0) ? (c[i] - obBear) / at : 0.0;
   }
}

void GRU_FVG(const double &o[], const double &h[], const double &l[],
             const double &c[], int n, double &inBull[], double &inBear[])
{
   double bullLo = 0.0, bullHi = 0.0, bearLo = 0.0, bearHi = 0.0;
   bool haveBull = false, haveBear = false;
   for(int i = 0; i < n; i++)
   {
      if(i >= 3)
      {
         if(h[i - 2] < l[i - 1]) { bullLo = h[i - 2]; bullHi = l[i - 1]; haveBull = true; }
         if(l[i - 2] > h[i - 1]) { bearLo = h[i - 1]; bearHi = l[i - 2]; haveBear = true; }
      }
      if(haveBull)
      {
         if(c[i] > bullHi) inBull[i] = 1.0;
         else if(l[i] <= bullLo) { haveBull = false; inBull[i] = 0.0; }
         else inBull[i] = 0.0;
      }
      else inBull[i] = 0.0;
      if(haveBear)
      {
         if(c[i] < bearLo) inBear[i] = 1.0;
         else if(h[i] >= bearHi) { haveBear = false; inBear[i] = 0.0; }
         else inBear[i] = 0.0;
      }
      else inBear[i] = 0.0;
   }
}

void GRU_RelSessVol(const double &v[], const datetime &t[], int n,
                    double &out[])
{
   int nDays = 0;
   datetime dayOf[256];
   double dayHourMean[256][24];
   int dayHourCnt[256][24];
   ZeroMemory(dayOf); ZeroMemory(dayHourMean); ZeroMemory(dayHourCnt);
   for(int i = 0; i < n; i++)
   {
      datetime d = t[i] / 86400;
      int hh = (int)((t[i] / 3600) % 24);
      int di = -1;
      for(int k = 0; k < nDays; k++) if(dayOf[k] == d) { di = k; break; }
      if(di < 0)
      {
         if(nDays >= 256) continue;
         di = nDays; dayOf[nDays++] = d;
      }
      dayHourMean[di][hh] += v[i];
      dayHourCnt[di][hh]++;
   }
   for(int k = 0; k < nDays; k++)
      for(int hh = 0; hh < 24; hh++)
         if(dayHourCnt[k][hh] > 0) dayHourMean[k][hh] /= (double)dayHourCnt[k][hh];

   for(int i = 0; i < n; i++)
   {
      datetime d = t[i] / 86400;
      int hh = (int)((t[i] / 3600) % 24);
      double sum = 0.0; int cnt = 0;
      for(int k = nDays - 1; k >= 0; k--)
      {
         if(dayOf[k] >= d) continue;
         if(dayHourCnt[k][hh] > 0) { sum += dayHourMean[k][hh]; cnt++; }
         if(cnt >= 20) break;
      }
      out[i] = (cnt >= 20 && sum > 0.0) ? v[i] / (sum / (double)cnt) : 0.0;
   }
}

//+------------------------------------------------------------------+
//| CGRUFilter76 — Ultimate 76 binary inference (M5 window).         |
//+------------------------------------------------------------------+
void LogDxyRow(datetime barTime, const datetime &dt_[], const double &do_[],
               const double &dh_[], const double &dl_[], const double &dc_[],
               const double &dxyAtrN[], const double &dxyRet1[],
               const double &dxyRet5[], const double &dxyRet12[],
               const double &dxyRet24[], const double &dxyZc20[],
               const double &dxyZc50[], double lastCorr, int mD);
class CGRUFilter76
{
private:
   string            m_modelPath;
   string            m_dxyPairs[6];
   long              m_onnxHandle;
   bool              m_initialized;

   double            m_inputData[GRU_SEQ_LEN * GRU_MAX_FEATURES];
   double            m_outputData[3];

   double            m_lastAtrNorm;

   bool              BuildWindow();
   void              Std(double &row[]);
   bool              BuildSyntheticDxy(MqlRates &dx[]);

   double            m_xOpen[GRU_M5_WARMUP], m_xHigh[GRU_M5_WARMUP],
                     m_xLow[GRU_M5_WARMUP], m_xClose[GRU_M5_WARMUP],
                     m_xVol[GRU_M5_WARMUP];
   double            m_dxyOpen[GRU_DXY_WARMUP], m_dxyHigh[GRU_DXY_WARMUP],
                     m_dxyLow[GRU_DXY_WARMUP], m_dxyClose[GRU_DXY_WARMUP];
   double            m_f[GRU_MAX_FEATURES];

public:
   CGRUFilter76();
   ~CGRUFilter76();

   bool              Initialize(string modelPath);
   bool              RunInference(double &bullProb, double &bearProb);
   void              Release();
};

CGRUFilter76::CGRUFilter76() :
   m_modelPath(""),
   m_onnxHandle(INVALID_HANDLE),
   m_initialized(false)
{
   ZeroMemory(m_inputData);
   ZeroMemory(m_outputData);
   m_lastAtrNorm = 0.0;
   m_dxyPairs[0] = "EURUSD"; m_dxyPairs[1] = "USDJPY"; m_dxyPairs[2] = "GBPUSD";
   m_dxyPairs[3] = "USDCAD";  m_dxyPairs[4] = "USDSEK"; m_dxyPairs[5] = "USDCHF";
}

CGRUFilter76::~CGRUFilter76()
{
   Release();
}

void CGRUFilter76::Release()
{
   if(m_onnxHandle != INVALID_HANDLE)
   {
      OnnxRelease(m_onnxHandle);
      m_onnxHandle = INVALID_HANDLE;
   }
   m_initialized = false;
}

bool CGRUFilter76::Initialize(string modelPath)
{
   m_modelPath = modelPath;
   if(StringLen(m_modelPath) == 0)
   {
      Print("[GRU CRITICAL] Model path is empty.");
      return false;
   }
   if(!FileIsExist(m_modelPath))
   {
      Print("[GRU CRITICAL] Model file not found: " + m_modelPath);
      return false;
   }

   string missing = "";
   for(int p = 0; p < 6; p++)
   {
      if(!SymbolSelect(m_dxyPairs[p], true))
      {
         if(missing != "") missing += ", ";
         missing += m_dxyPairs[p];
      }
   }
   if(missing != "")
      Print("[GRU WARNING] Synthetic DXY basket pairs not selectable: " + missing + " (DXY features will be zeroed, dxy_available=0).");

   if(!g_features42.Init(_Symbol, PERIOD_M5))
   {
      Print("[AI Engine] Failed to initialize 42-feature extraction.");
   }

   if(!g_onnx42.Init("gold_master_ai.onnx"))
   {
      Print("[AI Engine] Failed to initialize gold_master_ai.onnx.");
   }

   if(!g_mlpEngine.Init("gold_mlp_ai.onnx"))
   {
      Print("[AI Engine] Failed to initialize gold_mlp_ai.onnx (MLP Neural Net).");
   }

   m_initialized = true;
   PrintFormat("[AI Engine] Multi-Model Ensemble Initialized: LightGBM (gold_master_ai.onnx) + MLP (gold_mlp_ai.onnx) + Rules Engine.");
   return true;
}

void CGRUFilter76::Std(double &row[])
{
   for(int k = 0; k < GRU_MAX_FEATURES; k++)
   {
      double xsd = (GRU76_XSD[k] > 0.0) ? GRU76_XSD[k] : 1.0;
      double v = (row[k] - GRU76_XM[k]) / xsd;
      row[k] = MathMax(-5.0, MathMin(5.0, v));
   }
}

bool CGRUFilter76::BuildWindow()
{
   string sym = _Symbol;

   MqlRates m5[];
   int got = CopyRates(sym, PERIOD_M5, 1, GRU_M5_WARMUP, m5);
   if(got < GRU_SEQ_LEN + 250)
   {
      PrintFormat("[GRU] Not enough M5 history: %d", got);
      return false;
   }
   ArraySetAsSeries(m5, true);

   int N = got;
   double o[]; ArrayResize(o, N);
   double h[]; ArrayResize(h, N);
   double l[]; ArrayResize(l, N);
   double c[]; ArrayResize(c, N);
   double v[]; ArrayResize(v, N);
   datetime t[]; ArrayResize(t, N);
   for(int i = 0; i < N; i++)
   {
      int s = N - 1 - i;
      o[i] = m5[s].open;  h[i] = m5[s].high;  l[i] = m5[s].low;
      c[i] = m5[s].close; v[i] = (double)m5[s].tick_volume;
      t[i] = m5[s].time;
   }

   MqlRates h1[];
   int n1 = CopyRates(sym, PERIOD_H1, 1, GRU_H1_WARMUP, h1);
   if(n1 < 120) return false;
   ArraySetAsSeries(h1, true);
   double o1[]; ArrayResize(o1, n1);
   double hh1[]; ArrayResize(hh1, n1);
   double ll1[]; ArrayResize(ll1, n1);
   double cc1[]; ArrayResize(cc1, n1);
   datetime t1[]; ArrayResize(t1, n1);
   for(int i = 0; i < n1; i++)
   {
      int s = n1 - 1 - i;
      o1[i] = h1[s].open; hh1[i] = h1[s].high; ll1[i] = h1[s].low;
      cc1[i] = h1[s].close; t1[i] = h1[s].time;
   }

   MqlRates h4[];
   int n4 = CopyRates(sym, PERIOD_H4, 1, GRU_H4_WARMUP, h4);
   if(n4 < 80) return false;
   ArraySetAsSeries(h4, true);
   double o4[]; ArrayResize(o4, n4);
   double hh4[]; ArrayResize(hh4, n4);
   double ll4[]; ArrayResize(ll4, n4);
   double cc4[]; ArrayResize(cc4, n4);
   datetime t4[]; ArrayResize(t4, n4);
   for(int i = 0; i < n4; i++)
   {
      int s = n4 - 1 - i;
      o4[i] = h4[s].open; hh4[i] = h4[s].high; ll4[i] = h4[s].low;
      cc4[i] = h4[s].close; t4[i] = h4[s].time;
   }

   MqlRates d1[];
   int n2 = CopyRates(sym, PERIOD_D1, 1, GRU_D1_WARMUP, d1);
   if(n2 < 50) return false;
   ArraySetAsSeries(d1, true);
   double o2[]; ArrayResize(o2, n2);
   double hh2[]; ArrayResize(hh2, n2);
   double ll2[]; ArrayResize(ll2, n2);
   double cc2[]; ArrayResize(cc2, n2);
   datetime t2[]; ArrayResize(t2, n2);
   for(int i = 0; i < n2; i++)
   {
      int s = n2 - 1 - i;
      o2[i] = d1[s].open; hh2[i] = d1[s].high; ll2[i] = d1[s].low;
      cc2[i] = d1[s].close; t2[i] = d1[s].time;
   }

   double aRet1[], aRet5[], aRet12[], aRet24[], aRet48[], aMom6[];
   double aZc20[], aZc50[], aZc100[], aZh20[], aZh50[], aZh100[];
   double aZl20[], aZl50[], aZl100[];
   double aAtrRatio[], aAtrNorm[];
   double aRsi[], aRsiSlope[];
   double aMacdHist[], aMacdSlope[];
   double aDistVwap[], aDistEma20[], aDistEma50[], aDistEma200[];
   double aEma20Slope[], aEma50Slope[];
   double aBody[], aUp[], aLo[];
   double aVolRatio[];
   ArrayResize(aRet1, N); ArrayResize(aRet5, N); ArrayResize(aRet12, N);
   ArrayResize(aRet24, N); ArrayResize(aRet48, N); ArrayResize(aMom6, N);
   ArrayResize(aZc20, N); ArrayResize(aZc50, N); ArrayResize(aZc100, N);
   ArrayResize(aZh20, N); ArrayResize(aZh50, N); ArrayResize(aZh100, N);
   ArrayResize(aZl20, N); ArrayResize(aZl50, N); ArrayResize(aZl100, N);
   ArrayResize(aAtrRatio, N); ArrayResize(aAtrNorm, N);
   ArrayResize(aRsi, N); ArrayResize(aRsiSlope, N);
   ArrayResize(aMacdHist, N); ArrayResize(aMacdSlope, N);
   ArrayResize(aDistVwap, N); ArrayResize(aDistEma20, N);
   ArrayResize(aDistEma50, N); ArrayResize(aDistEma200, N);
   ArrayResize(aEma20Slope, N); ArrayResize(aEma50Slope, N);
   ArrayResize(aBody, N); ArrayResize(aUp, N); ArrayResize(aLo, N);
   ArrayResize(aVolRatio, N);

   double ema20[], ema50[], ema200[], macd[];
   ArrayResize(ema20, N); ArrayResize(ema50, N); ArrayResize(ema200, N);
   ArrayResize(macd, N);

   double tr[]; ArrayResize(tr, N);
   GRU_TR(h, l, c, N, tr);
   double atr14[], atr100[]; ArrayResize(atr14, N); ArrayResize(atr100, N);
   GRU_RollMean(tr, N, 14, atr14);
   GRU_RollMean(tr, N, 100, atr100);

   GRU_EMA(c, N, 12, macd);
   double ema26[]; ArrayResize(ema26, N);
   GRU_EMA(c, N, 26, ema26);
   for(int i = 0; i < N; i++) macd[i] -= ema26[i];

   GRU_EMA(c, N, 20, ema20);
   GRU_EMA(c, N, 50, ema50);
   GRU_EMA(c, N, 200, ema200);

   double vw[]; ArrayResize(vw, N);
   {
      double sTv = 0.0, sV = 0.0;
      for(int i = 0; i < N; i++)
      {
         double tp = (h[i] + l[i] + c[i]) / 3.0;
         sTv += tp * v[i]; sV += v[i];
         if(i >= 20) { int j = i - 20; double tpj = (h[j] + l[j] + c[j]) / 3.0; sTv -= tpj * v[j]; sV -= v[j]; }
         vw[i] = (i >= 19 && sV > 0.0) ? sTv / sV : c[i];
      }
   }
   double vMean[]; ArrayResize(vMean, N);
   GRU_RollMean(v, N, 20, vMean);

   double eps = 1e-12;
   for(int i = 0; i < N; i++)
   {
      aRet1[i]   = (i >= 1)  ? MathLog(c[i] / MathMax(c[i - 1], eps))  : 0.0;
      aRet5[i]   = (i >= 5)  ? MathLog(c[i] / MathMax(c[i - 5], eps))  : 0.0;
      aRet12[i]  = (i >= 12) ? MathLog(c[i] / MathMax(c[i - 12], eps)) : 0.0;
      aRet24[i]  = (i >= 24) ? MathLog(c[i] / MathMax(c[i - 24], eps)) : 0.0;
      aRet48[i]  = (i >= 48) ? MathLog(c[i] / MathMax(c[i - 48], eps)) : 0.0;
      aMom6[i]   = (i >= 6)  ? MathLog(c[i] / MathMax(c[i - 6], eps))  : 0.0;
      aAtrRatio[i] = (atr100[i] > 0.0) ? atr14[i] / atr100[i] : 0.0;
      aAtrNorm[i]  = atr14[i] / MathMax(c[i], eps);
      aMacdHist[i] = macd[i] / MathMax(c[i], eps);
      aDistVwap[i] = MathLog(c[i] / MathMax(vw[i], eps));
      aDistEma20[i]  = MathLog(c[i] / MathMax(ema20[i], eps));
      aDistEma50[i]  = MathLog(c[i] / MathMax(ema50[i], eps));
      aDistEma200[i] = MathLog(c[i] / MathMax(ema200[i], eps));
      double rng = MathMax(h[i] - l[i], eps);
      aBody[i] = (c[i] - o[i]) / rng;
      aUp[i] = (h[i] - MathMax(o[i], c[i])) / rng;
      aLo[i] = (MathMin(o[i], c[i]) - l[i]) / rng;
      aVolRatio[i] = (vMean[i] > 0.0) ? v[i] / vMean[i] : 1.0;
   }
   GRU_Zscore(c, N, 20, aZc20);  GRU_Zscore(c, N, 50, aZc50);  GRU_Zscore(c, N, 100, aZc100);
   GRU_Zscore(h, N, 20, aZh20);  GRU_Zscore(h, N, 50, aZh50);  GRU_Zscore(h, N, 100, aZh100);
   GRU_Zscore(l, N, 20, aZl20);  GRU_Zscore(l, N, 50, aZl50);  GRU_Zscore(l, N, 100, aZl100);
   GRU_RSI(c, N, 14, aRsi);
   GRU_Slope(aRsi, N, aRsiSlope);
   GRU_Slope(macd, N, aMacdSlope);
   GRU_Slope(ema20, N, aEma20Slope);
   GRU_Slope(ema50, N, aEma50Slope);

   double h1_ret1[], h1_ret4[], h1_zc20[], h1_zc50[], h1_atrR[], h1_rsi[], h1_de20[], h1_eslope[];
   double h1_de200[], h1_e200slope[];
   ArrayResize(h1_ret1, n1); ArrayResize(h1_ret4, n1); ArrayResize(h1_zc20, n1);
   ArrayResize(h1_zc50, n1); ArrayResize(h1_atrR, n1); ArrayResize(h1_rsi, n1);
   ArrayResize(h1_de20, n1); ArrayResize(h1_eslope, n1);
   ArrayResize(h1_de200, n1); ArrayResize(h1_e200slope, n1);
   {
      double tr1[]; ArrayResize(tr1, n1);
      double a14[], a100[]; ArrayResize(a14, n1); ArrayResize(a100, n1);
      double e20[]; ArrayResize(e20, n1);
      double e200[]; ArrayResize(e200, n1);
      GRU_TR(hh1, ll1, cc1, n1, tr1);
      GRU_RollMean(tr1, n1, 14, a14);
      GRU_RollMean(tr1, n1, 100, a100);
      GRU_EMA(cc1, n1, 20, e20);
      GRU_EMA(cc1, n1, 200, e200);
      GRU_RSI(cc1, n1, 14, h1_rsi);
      GRU_Zscore(cc1, n1, 20, h1_zc20);
      GRU_Zscore(cc1, n1, 50, h1_zc50);
      GRU_Slope(e20, n1, h1_eslope);
      GRU_Slope(e200, n1, h1_e200slope);
      for(int i = 0; i < n1; i++)
      {
         h1_ret1[i] = (i >= 1) ? MathLog(cc1[i] / MathMax(cc1[i - 1], 1e-12)) : 0.0;
         h1_ret4[i] = (i >= 4) ? MathLog(cc1[i] / MathMax(cc1[i - 4], 1e-12)) : 0.0;
         h1_atrR[i] = (a100[i] > 0.0) ? a14[i] / a100[i] : 0.0;
         h1_de20[i] = MathLog(cc1[i] / MathMax(e20[i], 1e-12));
         h1_de200[i] = MathLog(cc1[i] / MathMax(e200[i], 1e-12));
      }
   }

   double h4_ret1[], h4_ret4[], h4_zc20[], h4_de20[], h4_eslope[], h4_atrN[];
   double h4_de200[], h4_e200slope[];
   ArrayResize(h4_ret1, n4); ArrayResize(h4_ret4, n4); ArrayResize(h4_zc20, n4);
   ArrayResize(h4_de20, n4); ArrayResize(h4_eslope, n4); ArrayResize(h4_atrN, n4);
   ArrayResize(h4_de200, n4); ArrayResize(h4_e200slope, n4);
   {
      double tr4[]; ArrayResize(tr4, n4);
      double a14[]; ArrayResize(a14, n4);
      double e20[]; ArrayResize(e20, n4);
      double e200[]; ArrayResize(e200, n4);
      GRU_TR(hh4, ll4, cc4, n4, tr4);
      GRU_RollMean(tr4, n4, 14, a14);
      GRU_EMA(cc4, n4, 20, e20);
      GRU_EMA(cc4, n4, 200, e200);
      GRU_Zscore(cc4, n4, 20, h4_zc20);
      GRU_Slope(e20, n4, h4_eslope);
      GRU_Slope(e200, n4, h4_e200slope);
      for(int i = 0; i < n4; i++)
      {
         h4_ret1[i] = (i >= 1) ? MathLog(cc4[i] / MathMax(cc4[i - 1], 1e-12)) : 0.0;
         h4_ret4[i] = (i >= 4) ? MathLog(cc4[i] / MathMax(cc4[i - 4], 1e-12)) : 0.0;
         h4_de20[i] = MathLog(cc4[i] / MathMax(e20[i], 1e-12));
         h4_atrN[i] = a14[i] / MathMax(cc4[i], 1e-12);
         h4_de200[i] = MathLog(cc4[i] / MathMax(e200[i], 1e-12));
      }
   }

   double d1_ret1[], d1_ret5[], d1_zc20[], d1_de20[], d1_atrN[];
   ArrayResize(d1_ret1, n2); ArrayResize(d1_ret5, n2); ArrayResize(d1_zc20, n2);
   ArrayResize(d1_de20, n2); ArrayResize(d1_atrN, n2);
   {
      double tr2[]; ArrayResize(tr2, n2);
      double a14[]; ArrayResize(a14, n2);
      double e20[]; ArrayResize(e20, n2);
      GRU_TR(hh2, ll2, cc2, n2, tr2);
      GRU_RollMean(tr2, n2, 14, a14);
      GRU_EMA(cc2, n2, 20, e20);
      GRU_Zscore(cc2, n2, 20, d1_zc20);
      for(int i = 0; i < n2; i++)
      {
         d1_ret1[i] = (i >= 1) ? MathLog(cc2[i] / MathMax(cc2[i - 1], 1e-12)) : 0.0;
         d1_ret5[i] = (i >= 5) ? MathLog(cc2[i] / MathMax(cc2[i - 5], 1e-12)) : 0.0;
         d1_de20[i] = MathLog(cc2[i] / MathMax(e20[i], 1e-12));
         d1_atrN[i] = a14[i] / MathMax(cc2[i], 1e-12);
      }
   }

   double aObBull[], aObBear[], aFvgBull[], aFvgBear[], aMss[];
   double aRelSessVol[];
   ArrayResize(aObBull, N); ArrayResize(aObBear, N);
   ArrayResize(aFvgBull, N); ArrayResize(aFvgBear, N);
   ArrayResize(aMss, N);
   ArrayResize(aRelSessVol, N);
   GRU_OrderBlocks(o, h, l, c, atr14, N, 2, aObBull, aObBear);
   GRU_FVG(o, h, l, c, N, aFvgBull, aFvgBear);
   GRU_MSS(h, l, c, N, aMss);
   GRU_RelSessVol(v, t, N, aRelSessVol);

   double dxyRet1[], dxyRet5[], dxyRet12[], dxyRet24[];
   double dxyZc20[], dxyZc50[], dxyAtrN[];
   double gRet[], gRetAligned[], dRetAligned[], dCorr[];
   datetime dt_[];
   double do_[], dh_[], dl_[], dc_[];
   int mD = 0;
   {
      MqlRates dx[];
      if(!BuildSyntheticDxy(dx))
      {
         Print("[GRU WARNING] Synthetic DXY build failed; DXY features zeroed, dxy_available=0.");
      }
      else
      {
         mD = ArraySize(dx);
      }
      if(mD < GRU_SEQ_LEN + GRU_CORR_WINDOW + 100)
      {
         ArrayResize(dxyRet1, 1); ArrayResize(dxyRet5, 1);
         ArrayResize(dxyRet12, 1); ArrayResize(dxyRet24, 1);
         ArrayResize(dxyZc20, 1); ArrayResize(dxyZc50, 1); ArrayResize(dxyAtrN, 1);
         dxyRet1[0] = dxyRet5[0] = dxyRet12[0] = dxyRet24[0] = 0.0;
         dxyZc20[0] = dxyZc50[0] = dxyAtrN[0] = 0.0;
         ArrayResize(dt_, 1); dt_[0] = (datetime)0x7FFFFFFFFFFFFFFF;
         ArrayResize(gRet, N); ArrayResize(gRetAligned, N);
         ArrayResize(dRetAligned, N); ArrayResize(dCorr, N);
         for(int i = 0; i < N; i++) { gRet[i] = 0.0; gRetAligned[i] = 0.0; dRetAligned[i] = 0.0; dCorr[i] = 0.0; }
      }
      else
      {
         ArrayResize(do_, mD);
         ArrayResize(dh_, mD);
         ArrayResize(dl_, mD);
         ArrayResize(dc_, mD);
         ArrayResize(dt_, mD);
         for(int i = 0; i < mD; i++)
         {
            do_[i] = dx[i].open; dh_[i] = dx[i].high; dl_[i] = dx[i].low;
            dc_[i] = dx[i].close; dt_[i] = dx[i].time;
         }

         ArrayResize(dxyRet1, mD); ArrayResize(dxyRet5, mD);
         ArrayResize(dxyRet12, mD); ArrayResize(dxyRet24, mD);
         ArrayResize(dxyZc20, mD); ArrayResize(dxyZc50, mD); ArrayResize(dxyAtrN, mD);

         double dtr[]; ArrayResize(dtr, mD);
         GRU_TR(dh_, dl_, dc_, mD, dtr);
         double dA14[]; ArrayResize(dA14, mD);
         GRU_RollMean(dtr, mD, 14, dA14);
         GRU_Zscore(dc_, mD, 20, dxyZc20);
         GRU_Zscore(dc_, mD, 50, dxyZc50);
         for(int i = 0; i < mD; i++)
         {
            dxyRet1[i]  = (i >= 1)  ? MathLog(dc_[i] / MathMax(dc_[i - 1], 1e-12))  : 0.0;
            dxyRet5[i]  = (i >= 5)  ? MathLog(dc_[i] / MathMax(dc_[i - 5], 1e-12))  : 0.0;
            dxyRet12[i] = (i >= 12) ? MathLog(dc_[i] / MathMax(dc_[i - 12], 1e-12)) : 0.0;
            dxyRet24[i] = (i >= 24) ? MathLog(dc_[i] / MathMax(dc_[i - 24], 1e-12)) : 0.0;
            dxyAtrN[i]  = dA14[i] / MathMax(dc_[i], 1e-12);
         }

         ArrayResize(gRet, N); ArrayResize(gRetAligned, N); ArrayResize(dRetAligned, N);
         ArrayResize(dCorr, N);
         int jd = 0;
         for(int i = 0; i < N; i++)
         {
            gRet[i] = (i >= 1) ? MathLog(c[i] / MathMax(c[i - 1], 1e-12)) : 0.0;
            while(jd + 1 < mD && dt_[jd + 1] <= t[i]) jd++;
            bool hasD = (dt_[jd] <= t[i]);
            dRetAligned[i] = hasD ? dxyRet1[jd] : 0.0;
            gRetAligned[i] = gRet[i];
         }
         for(int i = 0; i < N; i++)
            dCorr[i] = GRU_CorrWin(gRetAligned, dRetAligned, i, GRU_CORR_WINDOW);
      }
   }

   int base = N - GRU_SEQ_LEN;
   int ih = 0, iq = 0, id = 0, jd = 0;
   for(int r = 0; r < GRU_SEQ_LEN; r++)
   {
      int i = base + r;
      datetime T = t[i];

      while(ih + 1 < n1 && (t1[ih + 1] + 3600) <= T) ih++;
      while(iq + 1 < n4 && (t4[iq + 1] + 14400) <= T) iq++;
      while(id + 1 < n2 && (t2[id + 1] + 86400) <= T) id++;
      while(jd + 1 < mD && dt_[jd + 1] <= T) jd++;

      int hour = (int)((T / 3600) % 24);
      int dow  = (int)(((T / 86400) + 3) % 7);

      double f[GRU_MAX_FEATURES];
      f[0]  = aRet1[i];   f[1]  = aRet5[i];   f[2]  = aRet12[i];
      f[3]  = aRet24[i];  f[4]  = aRet48[i];  f[5]  = aMom6[i];
      f[6]  = aZc20[i];   f[7]  = aZh20[i];   f[8]  = aZl20[i];
      f[9]  = aZc50[i];   f[10] = aZh50[i];   f[11] = aZl50[i];
      f[12] = aZc100[i];  f[13] = aZh100[i];  f[14] = aZl100[i];
      f[15] = aAtrRatio[i]; f[16] = aAtrNorm[i];
      f[17] = aRsi[i];    f[18] = aRsiSlope[i];
      f[19] = aMacdHist[i]; f[20] = aMacdSlope[i];
      f[21] = aDistVwap[i]; f[22] = aDistEma20[i]; f[23] = aDistEma50[i]; f[24] = aDistEma200[i];
      f[25] = aEma20Slope[i]; f[26] = aEma50Slope[i];
      f[27] = aBody[i];   f[28] = aUp[i];     f[29] = aLo[i];
      f[30] = aVolRatio[i];

      f[31] = aObBull[i];  f[32] = aObBear[i];
      f[33] = aFvgBull[i]; f[34] = aFvgBear[i];
      f[35] = aMss[i];

      f[36] = h1_ret1[ih]; f[37] = h1_ret4[ih];
      f[38] = h1_zc20[ih];  f[39] = h1_zc50[ih];
      f[40] = h1_atrR[ih];  f[41] = h1_rsi[ih];
      f[42] = h1_de20[ih];  f[43] = h1_eslope[ih];
      f[44] = h1_de200[ih]; f[45] = h1_e200slope[ih];

      f[46] = h4_ret1[iq]; f[47] = h4_ret4[iq];
      f[48] = h4_zc20[iq]; f[49] = h4_de20[iq];
      f[50] = h4_eslope[iq]; f[51] = h4_de200[iq];
      f[52] = h4_e200slope[iq]; f[53] = h4_atrN[iq];

      f[54] = d1_ret1[id]; f[55] = d1_ret5[id];
      f[56] = d1_zc20[id]; f[57] = d1_de20[id]; f[58] = d1_atrN[id];

      f[59] = MathSin(2.0 * M_PI * hour / 24.0);
      f[60] = MathCos(2.0 * M_PI * hour / 24.0);
      f[61] = MathSin(2.0 * M_PI * dow / 7.0);
      f[62] = MathCos(2.0 * M_PI * dow / 7.0);
      f[63] = (hour >= 0 && hour < 8)  ? 1.0 : 0.0;
      f[64] = (hour >= 8 && hour < 16) ? 1.0 : 0.0;
      f[65] = (hour >= 13 && hour < 22) ? 1.0 : 0.0;
      f[66] = aRelSessVol[i];

      bool hasD = (jd < mD && dt_[jd] <= T);
      f[67] = hasD ? dxyAtrN[jd]  : 0.0;
      f[68] = hasD ? dxyRet1[jd]  : 0.0;
      f[69] = hasD ? dxyRet5[jd]  : 0.0;
      f[70] = hasD ? dxyRet12[jd] : 0.0;
      f[71] = hasD ? dxyRet24[jd] : 0.0;
      f[72] = hasD ? dxyZc20[jd]  : 0.0;
      f[73] = hasD ? dxyZc50[jd]  : 0.0;
      f[74] = dCorr[i];
      f[75] = hasD ? 1.0 : 0.0;

      Std(f);
      for(int k = 0; k < GRU_MAX_FEATURES; k++)
         m_inputData[r * GRU_MAX_FEATURES + k] = f[k];
   }

   m_lastAtrNorm = aAtrNorm[base + GRU_SEQ_LEN - 1];

   LogDxyRow(t[base + GRU_SEQ_LEN - 1], dt_, do_, dh_, dl_, dc_, dxyAtrN,
             dxyRet1, dxyRet5, dxyRet12, dxyRet24, dxyZc20, dxyZc50,
             dCorr[base + GRU_SEQ_LEN - 1], mD);
   return true;
}

bool CGRUFilter76::BuildSyntheticDxy(MqlRates &dx[])
{
   MqlRates b0[], b1[], b2[], b3[], b4[], b5[];
   int n[6];
   int minN = INT_MAX;
   int nArr[6] = {0,0,0,0,0,0};
   nArr[0] = CopyRates(m_dxyPairs[0], PERIOD_M5, 0, GRU_DXY_WARMUP, b0);
   nArr[1] = CopyRates(m_dxyPairs[1], PERIOD_M5, 0, GRU_DXY_WARMUP, b1);
   nArr[2] = CopyRates(m_dxyPairs[2], PERIOD_M5, 0, GRU_DXY_WARMUP, b2);
   nArr[3] = CopyRates(m_dxyPairs[3], PERIOD_M5, 0, GRU_DXY_WARMUP, b3);
   nArr[4] = CopyRates(m_dxyPairs[4], PERIOD_M5, 0, GRU_DXY_WARMUP, b4);
   nArr[5] = CopyRates(m_dxyPairs[5], PERIOD_M5, 0, GRU_DXY_WARMUP, b5);
   for(int p = 0; p < 6; p++)
   {
      n[p] = nArr[p];
      if(n[p] < GRU_SEQ_LEN + GRU_CORR_WINDOW + 100) return false;
      if(n[p] < minN) minN = n[p];
   }
   ArraySetAsSeries(b0, false);
   ArraySetAsSeries(b1, false);
   ArraySetAsSeries(b2, false);
   ArraySetAsSeries(b3, false);
   ArraySetAsSeries(b4, false);
   ArraySetAsSeries(b5, false);

   int mD = minN;
   ArrayResize(dx, mD);
   int j0 = 0, j1 = 0, j2 = 0, j3 = 0, j4 = 0, j5 = 0;
   for(int i = 0; i < mD; i++)
   {
      datetime T = b0[i].time;
      while(j0 + 1 < n[0] && b0[j0 + 1].time <= T) j0++;
      while(j1 + 1 < n[1] && b1[j1 + 1].time <= T) j1++;
      while(j2 + 1 < n[2] && b2[j2 + 1].time <= T) j2++;
      while(j3 + 1 < n[3] && b3[j3 + 1].time <= T) j3++;
      while(j4 + 1 < n[4] && b4[j4 + 1].time <= T) j4++;
      while(j5 + 1 < n[5] && b5[j5 + 1].time <= T) j5++;

      double o[6], h[6], l[6], c[6];
      o[0]=b0[j0].open;  h[0]=b0[j0].high;  l[0]=b0[j0].low;  c[0]=b0[j0].close;
      o[1]=b1[j1].open;  h[1]=b1[j1].high;  l[1]=b1[j1].low;  c[1]=b1[j1].close;
      o[2]=b2[j2].open;  h[2]=b2[j2].high;  l[2]=b2[j2].low;  c[2]=b2[j2].close;
      o[3]=b3[j3].open;  h[3]=b3[j3].high;  l[3]=b3[j3].low;  c[3]=b3[j3].close;
      o[4]=b4[j4].open;  h[4]=b4[j4].high;  l[4]=b4[j4].low;  c[4]=b4[j4].close;
      o[5]=b5[j5].open;  h[5]=b5[j5].high;  l[5]=b5[j5].low;  c[5]=b5[j5].close;

      dx[i].time  = T;
      dx[i].open   = 50.14348112 * MathPow(o[0], -0.576) * MathPow(o[1], 0.136) * MathPow(o[2], -0.119) * MathPow(o[3], 0.091) * MathPow(o[4], 0.042) * MathPow(o[5], 0.036);
      dx[i].high   = 50.14348112 * MathPow(h[0], -0.576) * MathPow(h[1], 0.136) * MathPow(h[2], -0.119) * MathPow(h[3], 0.091) * MathPow(h[4], 0.042) * MathPow(h[5], 0.036);
      dx[i].low    = 50.14348112 * MathPow(l[0], -0.576) * MathPow(l[1], 0.136) * MathPow(l[2], -0.119) * MathPow(l[3], 0.091) * MathPow(l[4], 0.042) * MathPow(l[5], 0.036);
      dx[i].close  = 50.14348112 * MathPow(c[0], -0.576) * MathPow(c[1], 0.136) * MathPow(c[2], -0.119) * MathPow(c[3], 0.091) * MathPow(c[4], 0.042) * MathPow(c[5], 0.036);
   }
   return true;
}

bool CGRUFilter76::RunInference(double &bullProb, double &bearProb)
{
   bullProb = 0.0;
   bearProb = 0.0;

   float features[FEAT_COUNT];
   if(!g_features42.ExtractLatestFeatures(features))
      return false;

   // 1. LightGBM GBDT inference (gold_master_ai.onnx)
   float lgbm_b = 0.0f, lgbm_n = 0.0f, lgbm_r = 0.0f;
   if(!g_onnx42.PredictConsensus(features, lgbm_b, lgbm_n, lgbm_r))
      return false;

   float lgbmProbs[3] = {lgbm_b, lgbm_n, lgbm_r};

   // 2. MLP Neural Network inference (gold_mlp_ai.onnx)
   float mlp_b = lgbm_b, mlp_n = lgbm_n, mlp_r = lgbm_r;
   if(g_mlpEngine.IsInitialized())
   {
      g_mlpEngine.Predict(features, mlp_b, mlp_n, mlp_r);
   }
   float mlpProbs[3] = {mlp_b, mlp_n, mlp_r};

   // 3. Quantitative Rules Evaluation (GE_RulesEngine.mqh)
   RuleSignal rule = CRulesEngine::EvaluateRules(features);

   // 4. Multi-Model 3-Way Ensemble Consensus Voting
   EnsembleResult ensemble = EnsembleVote(lgbmProbs, mlpProbs, rule);

   // Pass back consensus probabilities
   if(ensemble.finalDirection == 0)
   {
      bullProb = MathMax(ensemble.ensembleConfidence, (double)lgbmProbs[0]);
      bearProb = MathMax(0.0, 1.0 - bullProb);
   }
   else if(ensemble.finalDirection == 2)
   {
      bearProb = MathMax(ensemble.ensembleConfidence, (double)lgbmProbs[2]);
      bullProb = MathMax(0.0, 1.0 - bearProb);
   }
   else
   {
      bullProb = (double)lgbmProbs[0];
      bearProb = (double)lgbmProbs[2];
   }

   PrintFormat("[EnsembleEngine] Direction: %s | Conf: %.2f (LGBM: %.2f, MLP: %.2f, Rule: %s %.2f) | Valid: %s",
               (ensemble.finalDirection == 0 ? "BULL" : (ensemble.finalDirection == 2 ? "BEAR" : "NEUTRAL")),
               ensemble.ensembleConfidence, lgbmProbs[(ensemble.finalDirection == 0 ? 0 : 2)],
               mlpProbs[(ensemble.finalDirection == 0 ? 0 : 2)], rule.ruleName, rule.confidence,
               (ensemble.execute ? "EXECUTE" : "HOLD"));

   return true;
}

//+------------------------------------------------------------------+
//| LogDxyRow — append the aligned synthetic-DXY bar used for the    |
//| current prediction to GoldDxyLog.csv (diagnostic; matches the     |
//| Python port's per-bar DXY features). Writes one row per bar.      |
//+------------------------------------------------------------------+
void LogDxyRow(datetime barTime, const datetime &dt_[], const double &do_[],
               const double &dh_[], const double &dl_[], const double &dc_[],
               const double &dxyAtrN[], const double &dxyRet1[],
               const double &dxyRet5[], const double &dxyRet12[],
               const double &dxyRet24[], const double &dxyZc20[],
               const double &dxyZc50[], double lastCorr, int mD)
{
   static int h = INVALID_HANDLE;
   if(h == INVALID_HANDLE)
   {
      h = FileOpen("GoldDxyLog.csv", FILE_READ | FILE_WRITE | FILE_ANSI);
      if(h == INVALID_HANDLE)
         return;
      FileSeek(h, 0, SEEK_END);
      if(FileSize(h) == 0)
         FileWriteString(h,
            "bar_time" + "," + "dxy_time" + "," + "dxy_open" + "," + "dxy_high" + "," +
            "dxy_low" + "," + "dxy_close" + "," + "dxy_atrN" + "," + "dxy_ret1" + "," +
            "dxy_ret5" + "," + "dxy_ret12" + "," + "dxy_ret24" + "," + "dxy_zc20" + "," +
            "dxy_zc50" + "," + "dxy_corr" + "," + "hasD" + "\r\n");
   }

   int jd = 0;
   while(jd + 1 < mD && dt_[jd + 1] <= barTime) jd++;
   bool hasD = (jd < mD && dt_[jd] <= barTime);

   string row =
      TimeToString(barTime, TIME_DATE | TIME_MINUTES) + "," +
      (hasD ? TimeToString(dt_[jd], TIME_DATE | TIME_MINUTES) : "") + "," +
      (hasD ? DoubleToString(do_[jd], 8) : "") + "," +
      (hasD ? DoubleToString(dh_[jd], 8) : "") + "," +
      (hasD ? DoubleToString(dl_[jd], 8) : "") + "," +
      (hasD ? DoubleToString(dc_[jd], 8) : "") + "," +
      (hasD ? DoubleToString(dxyAtrN[jd], 8) : "") + "," +
      (hasD ? DoubleToString(dxyRet1[jd], 8) : "") + "," +
      (hasD ? DoubleToString(dxyRet5[jd], 8) : "") + "," +
      (hasD ? DoubleToString(dxyRet12[jd], 8) : "") + "," +
      (hasD ? DoubleToString(dxyRet24[jd], 8) : "") + "," +
      (hasD ? DoubleToString(dxyZc20[jd], 8) : "") + "," +
      (hasD ? DoubleToString(dxyZc50[jd], 8) : "") + "," +
      (hasD ? DoubleToString(lastCorr, 8) : "") + "," +
      (hasD ? "true" : "false") + "\r\n";
   FileWriteString(h, row);
   FileFlush(h);
}

//+------------------------------------------------------------------+
//| RefreshGNNCache — recompute GNN swing channel lines once per bar |
//| (100-bar swing highs/lows) and publish ceiling/floor for the     |
//| boundary gate (GE_EntryGates reads them).                        |
//+------------------------------------------------------------------+
void RefreshGNNCache()
{
   int lookback = 100;
   double highs[];
   double lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   if(CopyHigh(_Symbol, _Period, 1, lookback, highs) <= 0 ||
      CopyLow(_Symbol, _Period, 1, lookback, lows) <= 0)
      return;

   int highCount = 0;
   int lowCount = 0;
   
   ArrayResize(g_rawGnnHighs, 0);
   ArrayResize(g_rawGnnLows, 0);

   for(int i = 2; i < lookback - 2; i++)
   {
      if(highs[i] > highs[i-1] && highs[i] > highs[i-2] &&
         highs[i] > highs[i+1] && highs[i] > highs[i+2])
      {
         ArrayResize(g_rawGnnHighs, highCount + 1);
         g_rawGnnHighs[highCount] = highs[i];
         highCount++;
      }
      if(lows[i] < lows[i-1] && lows[i] < lows[i-2] &&
         lows[i] < lows[i+1] && lows[i] < lows[i+2])
      {
         ArrayResize(g_rawGnnLows, lowCount + 1);
         g_rawGnnLows[lowCount] = lows[i];
         lowCount++;
      }
   }
   
   // Perform the dynamic tick update immediately
   UpdateLiveGnnBoundaries();
}

//+------------------------------------------------------------------+
//| UpdateLiveGnnBoundaries — dynamically evaluate swing levels     |
//| against live prices on every single tick (replaces static cache) |
//+------------------------------------------------------------------+
void UpdateLiveGnnBoundaries()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   int numHighs = ArraySize(g_rawGnnHighs);
   int numLows  = ArraySize(g_rawGnnLows);

   // 1. Filter and sort highs above ask
   double filteredHighs[];
   int fhCount = 0;
   for(int i = 0; i < numHighs; i++)
   {
      if(g_rawGnnHighs[i] > 0.0 && g_rawGnnHighs[i] > ask)
      {
         ArrayResize(filteredHighs, fhCount + 1);
         filteredHighs[fhCount] = g_rawGnnHighs[i];
         fhCount++;
      }
   }
   
   // Sort filteredHighs ascending (closest to ask first)
   for(int i = 0; i < fhCount - 1; i++)
   {
      for(int j = i + 1; j < fhCount; j++)
      {
         if(filteredHighs[j] < filteredHighs[i])
         {
            double temp = filteredHighs[i];
            filteredHighs[i] = filteredHighs[j];
            filteredHighs[j] = temp;
         }
      }
   }

   // 2. Filter and sort lows below bid
   double filteredLows[];
   int flCount = 0;
   for(int i = 0; i < numLows; i++)
   {
      if(g_rawGnnLows[i] > 0.0 && g_rawGnnLows[i] < bid)
      {
         ArrayResize(filteredLows, flCount + 1);
         filteredLows[flCount] = g_rawGnnLows[i];
         flCount++;
      }
   }
   
   // Sort filteredLows descending (closest to bid first)
   for(int i = 0; i < flCount - 1; i++)
   {
      for(int j = i + 1; j < flCount; j++)
      {
         if(filteredLows[j] > filteredLows[i])
         {
            double temp = filteredLows[i];
            filteredLows[i] = filteredLows[j];
            filteredLows[j] = temp;
         }
      }
   }

   // 3. Set ceiling and floor (closest)
   g_gnnCeiling = (fhCount > 0 ? filteredHighs[0] : 0.0);
   g_gnnFloor   = (flCount > 0 ? filteredLows[0] : 0.0);

   // 4. Publish upper/lower lines for the dashboard
   int ui = 0;
   for(int i = 0; i < MathMin(4, fhCount); i++)
   {
      g_gnnUpperLines[ui] = filteredHighs[i];
      ui++;
   }
   for(int i = ui; i < 4; i++) g_gnnUpperLines[i] = 0.0;
   g_gnnUpperCount = ui;

   int li = 0;
   for(int i = 0; i < MathMin(4, flCount); i++)
   {
      g_gnnLowerLines[li] = filteredLows[i];
      li++;
   }
   for(int i = li; i < 4; i++) g_gnnLowerLines[i] = 0.0;
   g_gnnLowerCount = li;
}

//+------------------------------------------------------------------+
//| Engine singleton + cache refresh (Step 2: ONE cached source keyed|
//| on new-bar-open). Called once per new bar from the orchestrator. |
//+------------------------------------------------------------------+
// Advanced Model variables & instantiations
CGRUFilter76 g_gru76;
CGRUAdvancedFilter g_gruAdvanced;

double g_cachedExpectedReturn12 = 0.0;
double g_cachedExpectedReturn24 = 0.0;
double g_cachedExpectedReturn48 = 0.0;

void UpdateOnnxCache()
{
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime == g_cachedOnnxBarTime)
      return;

   double bull = 0.0, bear = 0.0;
   bool ok = false;

   if(InpUseAdvancedModel)
   {
      float dirOut[9];
      float retOut[3];
      float regOut[2];
      
      ok = g_gruAdvanced.BuildWindow() && g_gruAdvanced.RunInference(dirOut, retOut, regOut);
      if(ok)
      {
         // Softmax for 12-bar horizon (dirOut[0] = BULL, dirOut[1] = RANGE, dirOut[2] = BEAR)
         double exp_bull = MathExp(dirOut[0]);
         double exp_range = MathExp(dirOut[1]);
         double exp_bear = MathExp(dirOut[2]);
         double sum_exp = exp_bull + exp_range + exp_bear;
         
         bull = sum_exp > 0.0 ? exp_bull / sum_exp : 0.0;
         bear = sum_exp > 0.0 ? exp_bear / sum_exp : 0.0;
         
         // expected returns @12/24/48
         g_cachedExpectedReturn12 = retOut[0];
         g_cachedExpectedReturn24 = retOut[1];
         g_cachedExpectedReturn48 = retOut[2];
         
         // softmax for regime (regOut[0] = CHOP, regOut[1] = TRENDING)
         double exp_reg_chop = MathExp(regOut[0]);
         double exp_reg_trend = MathExp(regOut[1]);
         double sum_reg = exp_reg_chop + exp_reg_trend;
         g_cachedRegimeTrendProb = sum_reg > 0.0 ? exp_reg_trend / sum_reg : 0.5;
         g_cachedRegimeChopProb = sum_reg > 0.0 ? exp_reg_chop / sum_reg : 0.5;
      }
   }
   else
   {
      ok = g_gru76.RunInference(bull, bear);
   }

   // Shift history
   g_histOnnxBull2  = g_histOnnxBull1;
   g_histOnnxBear2  = g_histOnnxBear1;
   g_histOnnxValid2 = g_histOnnxValid1;

   g_histOnnxBull1  = g_cachedOnnxValid ? g_cachedOnnxBull : 0.0;
   g_histOnnxBear1  = g_cachedOnnxValid ? g_cachedOnnxBear : 0.0;
   g_histOnnxValid1 = g_cachedOnnxValid;

   g_cachedOnnxBull    = bull;
   g_cachedOnnxBear    = bear;
   g_cachedOnnxMargin  = MathAbs(bull - bear);
   g_cachedOnnxValid   = ok;
   g_cachedOnnxBarTime = barTime;

   RefreshGNNCache();
   RefreshRegimeCache();

   string onnxClass = (bull > bear ? "BULL" : "BEAR");
   if(!ok) onnxClass = "N/A";
   LogOnnxPrediction(bull, bear, g_cachedOnnxMargin, onnxClass, ok);

   PrintFormat("[ONNX] Bar %s -> BULL %.3f | BEAR %.3f | valid %s | regime_trend %.3f | exp_ret12 %.5f",
               TimeToString(barTime), bull, bear, (ok ? "true" : "false"), g_cachedRegimeTrendProb, g_cachedExpectedReturn12);
}

//+------------------------------------------------------------------+
//| DispatchEnabledStrategies — each enabled strategy evaluates its  |
//| real entry condition, computes a direction, and funnels the      |
//| request through the single AttemptTradePlacement chokepoint.     |
//| All real logic lives here; the chokepoint owns permission.       |
//+------------------------------------------------------------------+
double DashRSI(const int shift)
{
   static int h = INVALID_HANDLE;
   if(h == INVALID_HANDLE) h = iRSI(_Symbol, _Period, 14, PRICE_CLOSE);
   if(h == INVALID_HANDLE) return -1.0;
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(h, 0, shift, 1, b) != 1) return -1.0;
   return b[0];
}

double DashATR(const int shift)
{
   static int h = INVALID_HANDLE;
   if(h == INVALID_HANDLE) h = iATR(_Symbol, _Period, 14);
   if(h == INVALID_HANDLE) return -1.0;
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(h, 0, shift, 1, b) != 1) return -1.0;
   return b[0];
}

double DashMA(const int period, const int shift)
{
   static int h50 = INVALID_HANDLE;
   static int h200 = INVALID_HANDLE;
   int h = INVALID_HANDLE;
   if(period == 50)
   {
      if(h50 == INVALID_HANDLE) h50 = iMA(_Symbol, _Period, 50, 0, MODE_EMA, PRICE_CLOSE);
      h = h50;
   }
   else if(period == 200)
   {
      if(h200 == INVALID_HANDLE) h200 = iMA(_Symbol, _Period, 200, 0, MODE_EMA, PRICE_CLOSE);
      h = h200;
   }
   else
   {
      h = iMA(_Symbol, _Period, period, 0, MODE_EMA, PRICE_CLOSE);
   }
   if(h == INVALID_HANDLE) return -1.0;
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(h, 0, shift, 1, b) != 1) return -1.0;
   return b[0];
}

double DashADX(const int shift)
{
   static int h = INVALID_HANDLE;
   if(h == INVALID_HANDLE) h = iADX(_Symbol, _Period, 14);
   if(h == INVALID_HANDLE) return -1.0;
   double b[]; ArraySetAsSeries(b, true);
   if(CopyBuffer(h, 0, shift, 1, b) != 1) return -1.0;
   return b[0];
}

//+------------------------------------------------------------------+
//| AI CALL LAYER — WebRequest-based LLM access.                     |
//| Primary provider = Groq (3s timeout). On any failure (HTTP error,|
//| timeout, empty content) the request fails over to OpenRouter     |
//| (8s timeout). Both endpoints are OpenAI-compatible               |
//| /chat/completions. Requires both URLs whitelisted under          |
//| Tools->Options->Expert Advisors->WebRequest and valid API keys   |
//| entered in the EA Inputs tab. The 3s/8s contract is from Step 8. |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| JsonEscape — escapes a string for embedding inside a JSON string |
//| (the prompt body). Quotes, backslashes and control chars become  |
//| their JSON escapes so the provider receives the verbatim text.   |
//+------------------------------------------------------------------+
string JsonEscape(const string s)
{
   string out = "";
   for(int i = 0; i < StringLen(s); i++)
   {
      ushort c = StringGetCharacter(s, i);
      if(c == '"')        out += "\\\"";
      else if(c == '\\')   out += "\\\\";
      else if(c == '\n')   out += "\\n";
      else if(c == '\r')   out += "\\r";
      else if(c == '\t')   out += "\\t";
      else                 out += ShortToString(c);
   }
   return out;
}

//+------------------------------------------------------------------+
//| ExtractChatContent — pulls the assistant "content" out of a      |
//| chat/completions response. Handles JSON-escaped quotes inside    |
//| the content string (so a nested JSON verdict survives intact).   |
//+------------------------------------------------------------------+
string ExtractChatContent(const string response)
{
   string key = "\"content\"";
   int start = StringFind(response, key);
   if(start < 0) return "";
   int colon = StringFind(response, ":", start + StringLen(key));
   if(colon < 0) return "";
   int q1 = StringFind(response, "\"", colon + 1);
   if(q1 < 0) return "";
   string out = "";
   bool closed = false;
   for(int i = q1 + 1; i < StringLen(response); i++)
   {
      ushort c = StringGetCharacter(response, i);
      if(c == '\\')
      {
         if(i + 1 < StringLen(response))
         {
            ushort n = StringGetCharacter(response, i + 1);
            if(n == 'n')       out += "\n";
            else if(n == 't')  out += "\t";
            else if(n == 'r')  out += "\r";
            else if(n == '"')  out += "\"";
            else if(n == '\\') out += "\\";
            else { out += "\\"; out += ShortToString(n); }
            i++;
         }
         continue;
      }
      if(c == '"')
      {
         closed = true;
         break;
      }
      out += ShortToString(c);
   }
   if(!closed) return "";
   return out;
}

//+------------------------------------------------------------------+
//| CallAISingle — one WebRequest POST to a chat/completions endpoint|
//| with a fixed timeout. Returns true + content on HTTP 200 with a  |
//| non-empty assistant message. Prints a reason on failure so the   |
//| user can see which provider failed and why.                      |
//+------------------------------------------------------------------+
bool CallAISingle(const string url, const string apiKey, const string model,
                  const string prompt, const int timeoutMs, string &content)
{
   content = "";
   if(apiKey == "")
   {
      Print("[AI WARN] No API key for " + url);
      return false;
   }

   string body = "{";
   body += "\"model\":\"" + model + "\",";
   body += "\"temperature\":" + DoubleToString(InpAITemperature, 2) + ",";
   body += "\"max_tokens\":" + IntegerToString(InpAIMaxTokens) + ",";
   body += "\"messages\":[{\"role\":\"user\",\"content\":\"" + JsonEscape(prompt) + "\"}]";
   body += "}";

   string headers = "Content-Type: application/json\r\nAuthorization: Bearer " + apiKey + "\r\n";
   char postData[];
   StringToCharArray(body, postData, 0, StringLen(body));
   char result[];
   string resultHeaders;

   ResetLastError();
   int status = WebRequest("POST", url, headers, timeoutMs, postData, result, resultHeaders);
   if(status == -1)
   {
      Print("[AI WARN] WebRequest failed (" + IntegerToString(GetLastError()) + ") on " + url);
      return false;
   }
   if(status != 200)
   {
      Print("[AI WARN] HTTP " + IntegerToString(status) + " from " + url);
      return false;
   }

   string raw = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   content = ExtractChatContent(raw);
   if(content == "")
   {
      Print("[AI WARN] Empty content from " + url);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| CallAI — the Step 8 3s/8s failover entry point.                  |
//| Groq is tried first (3s). If it fails, OpenRouter is tried (8s). |
//| Returns the assistant content string, or "" when both fail (the  |
//| caller treats "" identically to a timeout: verdict invalid,      |
//| trade fails closed).                                             |
//+------------------------------------------------------------------+
string CallAI(const string prompt)
{
   if(!InpUseAIIntelligence)
      return "";

   string content = "";
   if(InpGroqAPIKey != "" &&
      CallAISingle(InpGroqURL, InpGroqAPIKey, InpGroqModel, prompt, InpAIPrimaryTimeoutMs, content))
   {
      Print("[AI OK] Groq response received (HTTP 200) using model " + InpGroqModel);
      return content;
   }

   if(InpOpenRouterAPIKey != "" &&
      CallAISingle(InpOpenRouterURL, InpOpenRouterAPIKey, InpOpenRouterModel, prompt, InpAIFailoverTimeoutMs, content))
   {
      Print("[AI OK] OpenRouter response received (HTTP 200) using model " + InpOpenRouterModel);
      return content;
   }

   Print("[AI WARN] Both providers failed for prompt request.");
   return "";
}

//+------------------------------------------------------------------+
//| PROMPT 3 live wrapper — build the Setup prompt from live state,  |
//| call CallAI, and parse the verdict. Any failure yields an        |
//| invalid verdict (identical to a timeout).                        |
//+------------------------------------------------------------------+
SSetupVerdict RequestSetupVerdict(const string currentPrice, const string sessions,
                                  const string balance, const string equity,
                                  const string freeMargin, const string marginLevel,
                                  const string onnxClass, const string onnxProb, const string onnxMargin,
                                  const string gnnDistances, const string emaFanDetails,
                                  const string macroTrendStatus, const string vwapStatus,
                                  const string rsiStatus, const string spreadStatus,
                                  const string dailyRangeAnalysis, const string mtfConfluence,
                                  const string volOpensStatus, const string trendDirectionStatus,
                                  const string adx, const string atr, const string rsi,
                                  const string ema50, const string ema200, const string ema9,
                                  const string vwap, const string volSMA10, const string volSMA20,
                                  const string spread, const string newsList,
                                  const string m5Ohlc, const string h1h4Ohlc,
                                  const string candlePatterns, const string tradeHistory,
                                  const string smcDetails, const string maxPositions)
{
   SSetupVerdict v;
   v.valid      = false;
   v.decision   = "HOLD";
   v.conviction = 0;
   v.regime     = "";
   v.strategy   = "";
   v.reason     = "";

   string prompt = BuildPrompt_Setup(currentPrice, sessions, balance, equity, freeMargin, marginLevel,
                                     onnxClass, onnxProb, onnxMargin, gnnDistances, emaFanDetails,
                                     macroTrendStatus, vwapStatus, rsiStatus, spreadStatus,
                                     dailyRangeAnalysis, mtfConfluence, volOpensStatus, trendDirectionStatus,
                                     adx, atr, rsi, ema50, ema200, ema9,
                                     vwap, volSMA10, volSMA20, spread, newsList,
                                     m5Ohlc, h1h4Ohlc, candlePatterns, tradeHistory, smcDetails, maxPositions);
   string response = CallAI(prompt);
   if(response == "")
   {
      LogAIParseFailure("Setup", response);
      return v;
   }
   v = ParseSetupVerdict(response);
   if(!v.valid)
      LogAIParseFailure("Setup", response);
   return v;
}

//+------------------------------------------------------------------+
//| PROMPT 1 live wrapper — intraday trade verification.             |
//+------------------------------------------------------------------+
SIntradayVerdict RequestIntradayVerdict(const string signal, const string entryPrice,
                                        const string onnxClass, const string onnxProb, const string onnxMargin,
                                        const string resistance, const string resDist,
                                        const string support, const string supDist,
                                        const string rsi, const string atr,
                                        const string candleHistory)
{
   SIntradayVerdict v;
   v.valid   = false;
   v.allowed = false;
   v.reason  = "";

   string prompt = BuildPrompt_Intraday(signal, entryPrice, onnxClass, onnxProb, onnxMargin,
                                        resistance, resDist, support, supDist, rsi, atr, candleHistory);
   string response = CallAI(prompt);
   if(response == "")
   {
      LogAIParseFailure("Intraday", response);
      return v;
   }
   v = ParseIntradayVerdict(response);
   if(!v.valid)
      LogAIParseFailure("Intraday", response);
   return v;
}

//+------------------------------------------------------------------+
//| PROMPT 2 live wrapper — active position management (HOLD/CLOSE). |
//+------------------------------------------------------------------+
SPositionVerdict RequestPositionVerdict(const string strategyType, const string side,
                                        const string entryPrice, const string currentPrice,
                                        const string currentSL, const string currentProfit,
                                        const string onnxClass, const string onnxProb, const string onnxMargin,
                                        const string ohlcHistory)
{
   SPositionVerdict v;
   v.valid  = false;
   v.action = "HOLD";
   v.reason = "";

   string prompt = BuildPrompt_Position(strategyType, side, entryPrice, currentPrice,
                                        currentSL, currentProfit, onnxClass, onnxProb, onnxMargin, ohlcHistory);
   string response = CallAI(prompt);
   if(response == "")
   {
      LogAIParseFailure("Position", response);
      return v;
   }
   v = ParsePositionVerdict(response);
   if(!v.valid)
      LogAIParseFailure("Position", response);
   return v;
}

//+------------------------------------------------------------------+
//| Live AI context collectors — cheap MQL5 reads used to fill the   |
//| PROMPT 3 fields with REAL market state (no fabricated values).   |
//+------------------------------------------------------------------+
string AISessionName()
{
   datetime t = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int h = dt.hour;
   if(h >= 7 && h < 13)      return "London";
   if(h >= 13 && h < 21)     return "New York";
   if(h >= 21 || h < 2)      return "Sydney/Tokyo";
   return "Asia";
}

double AIVWAP()
{
   double sumTV = 0.0, sumV = 0.0;
   for(int k = 0; k < 100; k++)
   {
      double tp = (iHigh(_Symbol, _Period, k) + iLow(_Symbol, _Period, k) + iClose(_Symbol, _Period, k)) / 3.0;
      double v  = (double)iVolume(_Symbol, _Period, k);
      sumTV += tp * v;
      sumV  += v;
   }
   return (sumV > 0.0 ? sumTV / sumV : 0.0);
}

string AIGnnDistances()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string s = "";
   if(g_gnnUpperCount > 0)
      s += "Ceiling " + DoubleToString(g_gnnUpperLines[0], _Digits) + " (" + DoubleToString(bid - g_gnnUpperLines[0], 2) + " away); ";
   if(g_gnnLowerCount > 0)
      s += "Floor " + DoubleToString(g_gnnLowerLines[0], _Digits) + " (" + DoubleToString(g_gnnLowerLines[0] - bid, 2) + " away); ";
   return (s == "" ? "none" : s);
}

string AIEmaFanDetails()
{
   double e9   = DashMA(9, 0);
   double e21  = DashMA(21, 0);
   double e50  = DashMA(50, 0);
   double e200 = DashMA(200, 0);
   string arr = "9<21<50<200";
   if(e9 > e21)   arr = "9>21";
   if(e21 > e50)  arr += ">50";
   if(e50 > e200) arr += ">200";
   string s = "EMA9=" + DoubleToString(e9, _Digits) + ", EMA21=" + DoubleToString(e21, _Digits) +
              ", EMA50=" + DoubleToString(e50, _Digits) + ", EMA200=" + DoubleToString(e200, _Digits) +
              " (arrangement: " + arr + ")";
   return s;
}

string AIMacroTrendStatus()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double h1e200 = 0.0, d1e200 = 0.0;
   int h1h = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(h1h != INVALID_HANDLE)
   {
      double b[]; ArraySetAsSeries(b, true);
      if(CopyBuffer(h1h, 0, 0, 1, b) == 1) h1e200 = b[0];
   }
   int d1h = iMA(_Symbol, PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(d1h != INVALID_HANDLE)
   {
      double b[]; ArraySetAsSeries(b, true);
      if(CopyBuffer(d1h, 0, 0, 1, b) == 1) d1e200 = b[0];
   }
   string s = "Price vs H1 EMA200: " + (h1e200 > 0.0 ? (price > h1e200 ? "above (bull)" : "below (bear)") : "n/a");
   s += "; vs D1 EMA200: " + (d1e200 > 0.0 ? (price > d1e200 ? "above (bull)" : "below (bear)") : "n/a");
   return s;
}

string AIVwapStatus()
{
   double vwap = AIVWAP();
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (vwap > 0.0 ? (price > vwap ? "above VWAP (bull)" : "below VWAP (bear)") : "n/a");
}

string AIRsiStatus()
{
   double rsi = DashRSI(0);
   if(rsi < 0.0) return "n/a";
   if(rsi > InpRSIOverboughtLevel) return "overbought (" + DoubleToString(rsi, 1) + ")";
   if(rsi < InpRSIOversoldLevel)   return "oversold (" + DoubleToString(rsi, 1) + ")";
   return "neutral (" + DoubleToString(rsi, 1) + ")";
}

string AISpreadStatus()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return "current " + IntegerToString(spread) + " pts";
}

string AIDailyRangeAnalysis()
{
   double dHigh = iHigh(_Symbol, PERIOD_D1, 0);
   double dLow  = iLow(_Symbol, PERIOD_D1, 0);
   double atr   = DashATR(0);
   if(dHigh <= 0.0 || dLow <= 0.0) return "n/a";
   return "today range " + DoubleToString(dHigh - dLow, _Digits) + ", ATR " + (atr > 0.0 ? DoubleToString(atr, _Digits) : "n/a");
}

string AIMtfConfluence()
{
   string out = "";
   int tfs[3] = {(int)_Period, (int)PERIOD_H1, (int)PERIOD_H4};
   for(int i = 0; i < 3; i++)
   {
      double e50 = 0.0, e200 = 0.0;
      int h = iMA(_Symbol, (ENUM_TIMEFRAMES)tfs[i], 50, 0, MODE_EMA, PRICE_CLOSE);
      if(h != INVALID_HANDLE)
      {
         double b[]; ArraySetAsSeries(b, true);
         if(CopyBuffer(h, 0, 0, 1, b) == 1) e50 = b[0];
      }
      int h2 = iMA(_Symbol, (ENUM_TIMEFRAMES)tfs[i], 200, 0, MODE_EMA, PRICE_CLOSE);
      if(h2 != INVALID_HANDLE)
      {
         double b[]; ArraySetAsSeries(b, true);
         if(CopyBuffer(h2, 0, 0, 1, b) == 1) e200 = b[0];
      }
      string name = (i == 0 ? "M" + IntegerToString(PeriodSeconds(_Period) / 60) : (i == 1 ? "H1" : "H4"));
      out += name + ":" + (e50 > 0.0 && e200 > 0.0 ? (e50 > e200 ? "bull" : "bear") : "n/a") + " ";
   }
   return out;
}

string AIVolOpensStatus()
{
   double volNow = (double)iVolume(_Symbol, _Period, 0);
   double volAvg = 0.0;
   for(int k = 1; k <= 20; k++) volAvg += (double)iVolume(_Symbol, _Period, k);
   volAvg /= 20.0;
   return (volAvg > 0.0 ? (volNow > volAvg ? "above avg (" + DoubleToString(volNow, 0) + " vs " + DoubleToString(volAvg, 0) + ")" : "below avg") : "n/a");
}

string AITrendDirectionStatus()
{
   double e50  = DashMA(50, 0);
   double e200 = DashMA(200, 0);
   if(e50 <= 0.0 || e200 <= 0.0) return "n/a";
   return (e50 > e200 ? "bullish (EMA50>EMA200)" : "bearish (EMA50<EMA200)");
}

string AIOhlc(const int tf, const int bars)
{
   string out = "";
   for(int i = 1; i <= bars; i++)
   {
      if(i > 1) out += "; ";
      out += DoubleToString(iOpen(_Symbol, (ENUM_TIMEFRAMES)tf, i), _Digits) + "/" +
             DoubleToString(iHigh(_Symbol, (ENUM_TIMEFRAMES)tf, i), _Digits) + "/" +
             DoubleToString(iLow(_Symbol, (ENUM_TIMEFRAMES)tf, i), _Digits) + "/" +
             DoubleToString(iClose(_Symbol, (ENUM_TIMEFRAMES)tf, i), _Digits);
   }
   return out;
}

string AICandlePatterns()
{
   string out = "";
   for(int i = 1; i <= 3; i++)
   {
      double o = iOpen(_Symbol, _Period, i);
      double h = iHigh(_Symbol, _Period, i);
      double l = iLow(_Symbol, _Period, i);
      double c = iClose(_Symbol, _Period, i);
      string pat = "neutral";
      double body = MathAbs(c - o);
      double wick = h - l;
      if(wick > 0.0)
      {
         double upper = h - MathMax(o, c);
         double lower = MathMin(o, c) - l;
         if(upper > body && upper > lower) pat = "upper-wick rejection";
         else if(lower > body && lower > upper) pat = "lower-wick rejection";
         else if(c > o) pat = "bullish";
         else if(c < o) pat = "bearish";
         else pat = "doji";
      }
      if(i > 1) out += ", ";
      out += "bar" + IntegerToString(i) + " " + pat;
   }
   return out;
}

string AITradeHistory()
{
   datetime from = TimeCurrent() - 7 * 86400;
   if(!HistorySelect(from, TimeCurrent())) return "none";
   int total = HistoryDealsTotal();
   if(total == 0) return "none";
   int closes = 0;
   double net = 0.0;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT) continue;
      closes++;
      net += HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP);
   }
   return IntegerToString(closes) + " closed deals, net " + DoubleToString(net, 2) + " USD";
}

string AISmcDetails()
{
   double swingHigh = 0.0, swingLow = 0.0;
   for(int i = 5; i < 100; i++)
   {
      if(iHigh(_Symbol, _Period, i) > iHigh(_Symbol, _Period, i + 1) &&
         iHigh(_Symbol, _Period, i) > iHigh(_Symbol, _Period, i - 1))
      { swingHigh = iHigh(_Symbol, _Period, i); break; }
   }
   for(int i = 5; i < 100; i++)
   {
      if(iLow(_Symbol, _Period, i) < iLow(_Symbol, _Period, i + 1) &&
         iLow(_Symbol, _Period, i) < iLow(_Symbol, _Period, i - 1))
      { swingLow = iLow(_Symbol, _Period, i); break; }
   }
   string s = "Swing high " + (swingHigh > 0.0 ? DoubleToString(swingHigh, _Digits) : "n/a") +
              ", swing low " + (swingLow > 0.0 ? DoubleToString(swingLow, _Digits) : "n/a");
   return s;
}

//+------------------------------------------------------------------+
//| RefreshAIVerdict — build the full PROMPT 3 context from live     |
//| market state, request a verdict from CallAI (3s/8s failover),     |
//| parse it, and publish the result into g_aiEntryCtx so the        |
//| decision log and any AI-conviction gate see the real AI verdict. |
//| When AI is off or unavailable, aiActive=false (fail-closed,      |
//| exactly as today). Called once per new bar from the dispatcher.  |
//+------------------------------------------------------------------+
void RefreshAIVerdict()
{
   g_aiEntryCtx.aiActive = false;
   g_aiEntryCtx.conviction = 0;
   g_aiEntryCtx.reason = "";
   g_aiEntryCtx.dailyBiasState = "";

   if(!InpUseAIIntelligence)
      return;
   if(InpGroqAPIKey == "" && InpOpenRouterAPIKey == "")
   {
      Print("[AI WARN] InpUseAIIntelligence=on but no API keys set. Enter keys in the EA Inputs tab.");
      return;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double atr = DashATR(0);
   double rsi = DashRSI(0);
   double adx = DashADX(0);
   double vwap = AIVWAP();
   double e9   = DashMA(9, 0);
   double e50  = DashMA(50, 0);
   double e200 = DashMA(200, 0);
   double volS10 = 0.0, volS20 = 0.0;
   for(int k = 1; k <= 20; k++)
   {
      if(k <= 10) volS10 += (double)iVolume(_Symbol, _Period, k);
      volS20 += (double)iVolume(_Symbol, _Period, k);
   }
   volS10 /= 10.0; volS20 /= 20.0;

   string onnxClass = "N/A", onnxProb = "0.0", onnxMargin = "0.0";
   if(g_cachedOnnxValid)
   {
      onnxClass = (g_cachedOnnxBull > g_cachedOnnxBear ? "BULL" : "BEAR");
      onnxProb  = DoubleToString(MathMax(g_cachedOnnxBull, g_cachedOnnxBear) * 100.0, 1);
      onnxMargin = DoubleToString(g_cachedOnnxMargin, 3);
   }

   SSetupVerdict v = RequestSetupVerdict(
      DoubleToString(bid, _Digits), AISessionName(),
      DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
      DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
      DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2),
      DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), 1),
      onnxClass, onnxProb, onnxMargin,
      AIGnnDistances(), AIEmaFanDetails(),
      AIMacroTrendStatus(), AIVwapStatus(),
      AIRsiStatus(), AISpreadStatus(),
      AIDailyRangeAnalysis(), AIMtfConfluence(),
      AIVolOpensStatus(), AITrendDirectionStatus(),
      (adx >= 0.0 ? DoubleToString(adx, 1) : "n/a"),
      (atr > 0.0 ? DoubleToString(atr, _Digits) : "n/a"),
      (rsi >= 0.0 ? DoubleToString(rsi, 1) : "n/a"),
      (e50 > 0.0 ? DoubleToString(e50, _Digits) : "n/a"),
      (e200 > 0.0 ? DoubleToString(e200, _Digits) : "n/a"),
      (e9 > 0.0 ? DoubleToString(e9, _Digits) : "n/a"),
      (vwap > 0.0 ? DoubleToString(vwap, _Digits) : "n/a"),
      DoubleToString(volS10, 0), DoubleToString(volS20, 0),
      IntegerToString((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)),
      "No high-impact news feed available (EA does not fetch news).",
      AIOhlc((int)_Period, 10), AIOhlc((int)PERIOD_H1, 4) + " | H4: " + AIOhlc((int)PERIOD_H4, 3),
      AICandlePatterns(), AITradeHistory(), AISmcDetails(),
      IntegerToString(InpMaxConcurrentTrades));

   if(!v.valid)
      return;

   g_aiEntryCtx.aiActive       = true;
   g_aiEntryCtx.conviction     = v.conviction;
   g_aiEntryCtx.reason         = v.reason;
   g_aiEntryCtx.dailyBiasState = v.decision;

   PrintFormat("[AI VERDICT] decision=%s conviction=%d regime=%s strategy=%s reason=%s",
               v.decision, v.conviction, v.regime, v.strategy, v.reason);
}

void DispatchEnabledStrategies()
{
   RefreshAIVerdict();          // publish the live AI verdict into g_aiEntryCtx (fail-closed when off)

   double close0 = iClose(_Symbol, _Period, 0);
   double close1 = iClose(_Symbol, _Period, 1);
   double close2 = iClose(_Symbol, _Period, 2);
   double open1  = iOpen(_Symbol, _Period, 1);
   double high1  = iHigh(_Symbol, _Period, 1);
   double low1   = iLow(_Symbol, _Period, 1);
   double rsi    = DashRSI(0);

   // GNN_REVERSION: fade at the boundary lines (its own direction engine)
   if(InpUseGnnReversion && g_gnnCeiling > 0.0 && g_gnnFloor > 0.0)
   {
      if(close0 <= g_gnnFloor + InpGnnTouchThreshold)
      {
         if(AttemptTradePlacement("GNN_REVERSION", "BUY")) g_activeTradeSetup = "GNN_REVERSION";
      }
      else if(close0 >= g_gnnCeiling - InpGnnTouchThreshold)
      {
         if(AttemptTradePlacement("GNN_REVERSION", "SELL")) g_activeTradeSetup = "GNN_REVERSION";
      }
   }

   // ONNX_CORE: the model's own direction, no strategy overlay
   if(InpUseOnnxCorePath && g_cachedOnnxValid)
   {
      if(g_cachedOnnxBull > g_cachedOnnxBear)
      {
         if(AttemptTradePlacement("ONNX_CORE", "BUY")) g_activeTradeSetup = "ONNX_CORE";
      }
      else if(g_cachedOnnxBear > g_cachedOnnxBull)
      {
         if(AttemptTradePlacement("ONNX_CORE", "SELL")) g_activeTradeSetup = "ONNX_CORE";
      }
   }

   // MOMENTUM_CONFIRM: fast, purely price-based streak entry for the "sticky
   // confidence" scenario (price moves for N+ consecutive bars while ONNX lags
   // below the 0.70 core bar). Fires ONLY when BOTH hold:
   //   1. N consecutive same-direction closes (N = InpMomentumConsecutiveBars)
   //   2. ONNX leans the same direction (prob > InpMomentumMinOnnxProb, NOT 0.70)
   // Fixed lot sizing (0.01 lots / $20 risk) handled in AttemptTradePlacement.
   // NOTE ON CRASH-2: in isolation momentum's CRASH-2 margin is weak (0.16) and
   // it is only acceptable because the combined system's margin holds (6.86).
   if(InpUseMomentumConfirm && g_cachedOnnxValid)
   {
      int nBars = MathMax(2, InpMomentumConsecutiveBars);
      bool upStreak  = true;
      bool dnStreak  = true;
      // Use CLOSED bars only (shifts 1..nBars+1; shift 0 is the forming candle).
      // Matches the backtest: streak of N closed M5 bars ending at the last close.
      for(int b = 1; b <= nBars; b++)
      {
         double cCur  = iClose(_Symbol, _Period, b);
         double cPrev = iClose(_Symbol, _Period, b + 1);
         if(cCur <= cPrev) upStreak = false;
         if(cCur >= cPrev) dnStreak = false;
      }
      if(upStreak && g_cachedOnnxBull > InpMomentumMinOnnxProb)
         AttemptTradePlacement("MOMENTUM_CONFIRM", "BUY");
      else if(dnStreak && g_cachedOnnxBear > InpMomentumMinOnnxProb)
         AttemptTradePlacement("MOMENTUM_CONFIRM", "SELL");
   }

   // BREAKOUT: close above prior-bar high (up) / below prior-bar low (down)
   if(InpUseStrategy_Breakout)
   {
      if(close1 > high1 && close0 > high1)
         AttemptTradePlacement("BREAKOUT", "BUY");
      else if(close1 < low1 && close0 < low1)
         AttemptTradePlacement("BREAKOUT", "SELL");
   }

   // VOLUME_BREAKOUT: same breakout shape with volume confirmation
   if(InpUseStrategy_VolumeBreakout)
   {
      double vol0 = (double)iVolume(_Symbol, _Period, 0);
      double volAvg = 0.0;
      for(int k = 1; k <= InpRegimeVolSMAPeriod; k++) volAvg += (double)iVolume(_Symbol, _Period, k);
      volAvg /= InpRegimeVolSMAPeriod;
      if(volAvg > 0.0 && vol0 > volAvg * InpBreakoutVolMult)
      {
         if(close1 > high1 && close0 > high1)
            AttemptTradePlacement("VOLUME_BREAKOUT", "BUY");
         else if(close1 < low1 && close0 < low1)
            AttemptTradePlacement("VOLUME_BREAKOUT", "SELL");
      }
   }

   // PULLBACK: retrace into the trend (EMA50) then resume in its direction
   if(InpUseStrategy_Pullback)
   {
      double ema50 = DashMA(50, 0);
      double ema200 = DashMA(200, 0);
      if(ema200 > 0.0 && ema50 > 0.0)
      {
         if(ema50 > ema200 && close1 <= ema50 && close0 > ema50)
            AttemptTradePlacement("PULLBACK", "BUY");
         else if(ema50 < ema200 && close1 >= ema50 && close0 < ema50)
            AttemptTradePlacement("PULLBACK", "SELL");
      }
   }

   // VWAP_PULLBACK: price tags VWAP and bounces with RSI in the buy/sell band
   if(InpUseStrategy_VWAPPullback)
   {
      double vwap = 0.0;
      double sumTV = 0.0, sumV = 0.0;
      for(int k = 0; k < 20; k++)
      {
         double tp = (iHigh(_Symbol, _Period, k) + iLow(_Symbol, _Period, k) + iClose(_Symbol, _Period, k)) / 3.0;
         double v = (double)iVolume(_Symbol, _Period, k);
         sumTV += tp * v; sumV += v;
      }
      if(sumV > 0.0) vwap = sumTV / sumV;

      if(vwap > 0.0)
      {
         if(close1 <= vwap && close0 > vwap && rsi >= InpVwapRsiBuyLow && rsi <= InpVwapRsiBuyHigh)
            AttemptTradePlacement("VWAP_PULLBACK", "BUY");
         else if(close1 >= vwap && close0 < vwap && rsi >= InpVwapRsiSellLow && rsi <= InpVwapRsiSellHigh)
            AttemptTradePlacement("VWAP_PULLBACK", "SELL");
      }
   }

   // MEAN_REVERSION: oversold/overbought snap-back (ranges only — ADX guard)
   if(InpUseStrategy_MeanReversion)
   {
      double adx = DashADX(0);
      if(adx >= 0.0 && adx < InpADXTrendGuard)
      {
         if(rsi < InpRSIOversoldLevel && close0 > low1)
            AttemptTradePlacement("MEAN_REVERSION", "BUY");
         else if(rsi > InpRSIOverboughtLevel && close0 < high1)
            AttemptTradePlacement("MEAN_REVERSION", "SELL");
      }
   }

   // SCALPING: fast intraday momentum after a tight consolidation (Donchian 5)
   if(InpUseStrategy_Scalping)
   {
      int idxH = iHighest(_Symbol, _Period, MODE_HIGH, 5, 1);
      int idxL = iLowest(_Symbol, _Period, MODE_LOW, 5, 1);
      double dHigh = (idxH >= 0 ? iHigh(_Symbol, _Period, idxH) : 0.0);
      double dLow  = (idxL >= 0 ? iLow(_Symbol, _Period, idxL)  : 0.0);
      double atr1  = DashATR(1);
      if(dHigh > 0.0 && dLow > 0.0 && (dHigh - dLow) < 0.50 * MathMax(atr1, 0.1))
      {
         if(close0 > dHigh)
            AttemptTradePlacement("SCALPING", "BUY");
         else if(close0 < dLow)
            AttemptTradePlacement("SCALPING", "SELL");
      }
   }

   // DONCHIAN_BREAKOUT: 20-bar Donchian channel break
   if(InpUseStrategy_Donchian)
   {
      int idxH = iHighest(_Symbol, _Period, MODE_HIGH, 20, 1);
      int idxL = iLowest(_Symbol, _Period, MODE_LOW, 20, 1);
      double dHigh = (idxH >= 0 ? iHigh(_Symbol, _Period, idxH) : 0.0);
      double dLow  = (idxL >= 0 ? iLow(_Symbol, _Period, idxL)  : 0.0);
      if(dHigh > 0.0 && dLow > 0.0)
      {
         if(close0 > dHigh)
            AttemptTradePlacement("DONCHIAN_BREAKOUT", "BUY");
         else if(close0 < dLow)
            AttemptTradePlacement("DONCHIAN_BREAKOUT", "SELL");
      }
   }

   // STRADDLE: range compression then expansion (ATR squeeze breakout)
   if(InpUseStrategy_Straddle)
   {
      double atrNow = DashATR(0);
      double atrPrev = 0.0;
      for(int k = 1; k <= 14; k++) atrPrev += DashATR(k);
      atrPrev /= 14.0;
      if(atrNow >= 0.0 && atrPrev > 0.0 && atrNow > atrPrev * InpVolatilitySpikeRatio)
      {
         if(close1 > high1)
            AttemptTradePlacement("STRADDLE", "BUY");
         else if(close1 < low1)
            AttemptTradePlacement("STRADDLE", "SELL");
      }
   }

   // EXHAUSTION_REENTRY: extreme RSI + long wick rejection at a key level
   if(InpUseStrategy_ExhaustionReentry)
   {
      double body = MathAbs(close1 - open1);
      double range = MathMax(high1 - low1, 1e-10);
      double upWick = (high1 - MathMax(open1, close1)) / range;
      double loWick = (MathMin(open1, close1) - low1) / range;
      if(rsi > InpRSIOverboughtLevel && upWick > 0.50)
         AttemptTradePlacement("EXHAUSTION_REENTRY", "SELL");
      else if(rsi < InpRSIOversoldLevel && loWick > 0.50)
         AttemptTradePlacement("EXHAUSTION_REENTRY", "BUY");
   }
}

#endif // GE_AIINTEGRATION_MQH
