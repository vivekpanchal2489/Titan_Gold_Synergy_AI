//+------------------------------------------------------------------+
//|                                             GE_RulesEngine.mqh   |
//|               Quantitative Market Structure Rule-Based Engine    |
//|             Deterministic Sanity & Confirmation Layer for MT5    |
//+------------------------------------------------------------------+
#ifndef GE_RULESENGINE_MQH
#define GE_RULESENGINE_MQH

struct RuleSignal
{
   int    direction;   // 0=Bull, 1=Neutral, 2=Bear
   double confidence;
   bool   active;
   string ruleName;
};

class CRulesEngine
{
public:
   static RuleSignal EvaluateRules(const float &features[])
   {
      RuleSignal signal;
      signal.direction  = 1; // Default Neutral
      signal.confidence = 0.0;
      signal.active     = false;
      signal.ruleName   = "NONE";

      // Array size guard
      if(ArraySize(features) < 76)
         return signal;

      // RULE 1: Strong Lower Wick Rejection + Volume Surge (Bullish Exhaustion Reversal)
      // features[8] = lower_wick_ratio > 0.45, features[66] = rel_volume_surge > 1.30, features[0] = of_buy_vol_ratio > 0.52
      if(features[8] > 0.45 && features[66] > 1.30 && features[0] > 0.52)
      {
         signal.direction  = 0; // Bull
         signal.confidence = 0.68;
         signal.active     = true;
         signal.ruleName   = "BULL_WICK_VOL_SURGE";
         return signal;
      }

      // RULE 1B: Strong Upper Wick Rejection + Volume Surge (Bearish Exhaustion Reversal)
      // features[7] = upper_wick_ratio > 0.45, features[66] = rel_volume_surge > 1.30, features[1] = of_sell_vol_ratio > 0.52
      if(features[7] > 0.45 && features[66] > 1.30 && features[1] > 0.52)
      {
         signal.direction  = 2; // Bear
         signal.confidence = 0.68;
         signal.active     = true;
         signal.ruleName   = "BEAR_WICK_VOL_SURGE";
         return signal;
      }

      // RULE 2: Overextension Fade + Trend Exhaustion
      // features[24] = dist_ema20_m5 > 2.0 ATR, features[73] = adx_14_regime < 0.40 (Normalized ADX < 20)
      if(features[24] > 2.0 && features[73] < 0.40)
      {
         signal.direction  = 2; // Bear (Mean Reversion)
         signal.confidence = 0.62;
         signal.active     = true;
         signal.ruleName   = "OVEREXT_BEAR_FADE";
         return signal;
      }
      else if(features[24] < -2.0 && features[73] < 0.40)
      {
         signal.direction  = 0; // Bull (Mean Reversion)
         signal.confidence = 0.62;
         signal.active     = true;
         signal.ruleName   = "OVEREXT_BULL_FADE";
         return signal;
      }

      // RULE 3: Session Transition + Volume Drop (Avoid / Neutral)
      if(MathAbs(features[60]) > 0.90 && features[66] < 0.50)
      {
         signal.direction  = 1; // Neutral
         signal.confidence = 0.70;
         signal.active     = true;
         signal.ruleName   = "SESSION_CHOP_AVOID";
         return signal;
      }

      // RULE 4: Bullish/Bearish Causal FVG Reaction
      if(features[11] > 0.50 && features[13] < 0.0)
      {
         signal.direction  = 0; // Bull
         signal.confidence = 0.65;
         signal.active     = true;
         signal.ruleName   = "BULL_FVG_SWEEP";
         return signal;
      }
      else if(features[12] > 0.50 && features[13] > 0.0)
      {
         signal.direction  = 2; // Bear
         signal.confidence = 0.65;
         signal.active     = true;
         signal.ruleName   = "BEAR_FVG_SWEEP";
         return signal;
      }

      return signal;
   }
};

#endif // GE_RULESENGINE_MQH
