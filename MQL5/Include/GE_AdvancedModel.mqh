//+------------------------------------------------------------------+
//| GE_AdvancedModel.mqh                                              |
//| Handles loading and running the 3-head Advanced model (ONNX).   |
//+------------------------------------------------------------------+
#property copyright "Antigravity"
#property version   "1.00"

#include <GE_AdvancedModelStats.mqh>

// MT5 ONNX API functions
#import "wined3d.dll"
#import

// Session times constants
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Global helper function to get Live Orderflow aggregates from tick cache
bool GetLiveOrderFlow(datetime &m5_times[], double &of_buy_vol[], double &of_sell_vol[], 
                      double &of_trade_count[], double &of_total_vol[], double &of_avg_trade[], 
                      double &of_max_trade[], double &of_imbalance[])
{
   int N = ArraySize(m5_times);
   ArrayResize(of_buy_vol, N); ArrayInitialize(of_buy_vol, 0.0);
   ArrayResize(of_sell_vol, N); ArrayInitialize(of_sell_vol, 0.0);
   ArrayResize(of_trade_count, N); ArrayInitialize(of_trade_count, 0.0);
   ArrayResize(of_total_vol, N); ArrayInitialize(of_total_vol, 0.0);
   ArrayResize(of_avg_trade, N); ArrayInitialize(of_avg_trade, 0.0);
   ArrayResize(of_max_trade, N); ArrayInitialize(of_max_trade, 0.0);
   ArrayResize(of_imbalance, N); ArrayInitialize(of_imbalance, 0.0);
   
   datetime t_start = m5_times[0];
   datetime t_end = m5_times[N - 1] + 300;
   
   MqlTick ticks[];
   int tc = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, t_start, t_end);
   if(tc <= 0)
   {
      return false;
   }
      
   double last_price = 0;
   for(int k = 0; k < tc; k++)
   {
      double price = (ticks[k].last > 0) ? ticks[k].last : ticks[k].bid;
      double vol = (ticks[k].volume_real > 0) ? ticks[k].volume_real 
                                              : ((ticks[k].volume > 0) ? (double)ticks[k].volume : 1.0);
      
      enum ENUM_LAST_DIR_LIVE { LAST_DIR_LIVE_NONE, LAST_DIR_LIVE_BUY, LAST_DIR_LIVE_SELL };
      static ENUM_LAST_DIR_LIVE last_direction = LAST_DIR_LIVE_NONE;
      
      bool is_buy = false;
      bool is_sell = false;
      
      if(price > last_price && last_price > 0)
      {
         is_buy = true;
         last_direction = LAST_DIR_LIVE_BUY;
      }
      else if(price < last_price && last_price > 0)
      {
         is_sell = true;
         last_direction = LAST_DIR_LIVE_SELL;
      }
      else // price == last_price
      {
         if(last_direction == LAST_DIR_LIVE_BUY)
            is_buy = true;
         else if(last_direction == LAST_DIR_LIVE_SELL)
            is_sell = true;
         else // Fallback if no direction established yet
         {
            if((ticks[k].flags & TICK_FLAG_BUY) != 0)
            {
               is_buy = true;
               last_direction = LAST_DIR_LIVE_BUY;
            }
            else if((ticks[k].flags & TICK_FLAG_SELL) != 0)
            {
               is_sell = true;
               last_direction = LAST_DIR_LIVE_SELL;
            }
         }
      }
      
      last_price = price;
      
      datetime bar_start = ticks[k].time - (ticks[k].time % 300);
      
      int idx = -1;
      for(int i = N - 1; i >= 0; i--)
      {
         if(m5_times[i] == bar_start)
         {
            idx = i;
            break;
         }
         if(m5_times[i] < bar_start)
            break;
      }
      
      if(idx >= 0)
      {
         of_trade_count[idx]++;
         of_total_vol[idx] += vol;
         if(vol > of_max_trade[idx])
            of_max_trade[idx] = vol;
            
         if(is_buy)
            of_buy_vol[idx] += vol;
         else if(is_sell)
            of_sell_vol[idx] += vol;
      }
   }
   
   for(int i = 0; i < N; i++)
   {
      double buy = of_buy_vol[i];
      double sell = of_sell_vol[i];
      of_imbalance[i] = (buy + sell) > 0.0 ? (buy - sell) / (buy + sell) : 0.0;
      of_avg_trade[i] = (of_trade_count[i] > 0.0) ? of_total_vol[i] / of_trade_count[i] : 0.0;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Class CGRUAdvancedFilter                                          |
//+------------------------------------------------------------------+
class CGRUAdvancedFilter
{
private:
   string            m_modelPath;
   long              m_onnxHandle;
   bool              m_initialized;
   
   // Input features array for the sequence [96 * 108]
   float             m_inputData[96 * GRU_ADVANCED_FEATURES];
   
   // Synthetic DXY helper variables
   string            m_dxyPairs[6];
   double            m_dxyOpen[3000], m_dxyHigh[3000],
                     m_dxyLow[3000], m_dxyClose[3000];

   // Feature extraction sub-helper functions
   void              Std(double &row[]);
   bool              BuildSyntheticDxy(MqlRates &dx[]);
                                      
public:
                     CGRUAdvancedFilter();
                    ~CGRUAdvancedFilter();
                    
   bool              Init(string modelPath);
   bool              BuildWindow();
   bool              RunInference(float &dirOutputs[], float &retOutputs[], float &regOutputs[]);
   bool              IsInitialized() { return m_initialized; }
};

//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CGRUAdvancedFilter::CGRUAdvancedFilter() :
   m_onnxHandle(INVALID_HANDLE),
   m_initialized(false)
{
   m_dxyPairs[0] = "EURUSD"; m_dxyPairs[1] = "USDJPY"; m_dxyPairs[2] = "GBPUSD";
   m_dxyPairs[3] = "USDCAD"; m_dxyPairs[4] = "USDSEK"; m_dxyPairs[5] = "USDCHF";
   ArrayInitialize(m_inputData, 0.0f);
}

//+------------------------------------------------------------------+
//| Destructor                                                       |
//+------------------------------------------------------------------+
CGRUAdvancedFilter::~CGRUAdvancedFilter()
{
   if(m_onnxHandle != INVALID_HANDLE)
   {
      OnnxRelease(m_onnxHandle);
      m_onnxHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Initialize ONNX Model                                            |
//+------------------------------------------------------------------+
bool CGRUAdvancedFilter::Init(string modelPath)
{
   m_modelPath = modelPath;
   
   // Enable symbols for synthetic DXY
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
      Print("[GRU ADVANCED WARNING] Synthetic DXY basket pairs not selectable: " + missing);

   m_onnxHandle = OnnxCreate(m_modelPath, ONNX_DEFAULT);
   if(m_onnxHandle == INVALID_HANDLE)
   {
      Print("[GRU ADVANCED CRITICAL] OnnxCreate failed. Error: " + IntegerToString(GetLastError()));
      return false;
   }

   const long inShape[] = {1, 96, GRU_ADVANCED_FEATURES};
   if(!OnnxSetInputShape(m_onnxHandle, 0, inShape))
   {
      Print("[GRU ADVANCED CRITICAL] OnnxSetInputShape failed. Error: " + IntegerToString(GetLastError()));
      OnnxRelease(m_onnxHandle);
      m_onnxHandle = INVALID_HANDLE;
      return false;
   }

   // Outputs shapes:
   // Output 0 (dir) = [1, 9]
   const long dirShape[] = {1, 9};
   if(!OnnxSetOutputShape(m_onnxHandle, 0, dirShape))
   {
      Print("[GRU ADVANCED CRITICAL] OnnxSetOutputShape 0 failed. Error: " + IntegerToString(GetLastError()));
      return false;
   }
   
   // Output 1 (ret) = [1, 3]
   const long retShape[] = {1, 3};
   if(!OnnxSetOutputShape(m_onnxHandle, 1, retShape))
   {
      Print("[GRU ADVANCED CRITICAL] OnnxSetOutputShape 1 failed. Error: " + IntegerToString(GetLastError()));
      return false;
   }

   // Output 2 (regime) = [1, 2]
   const long regShape[] = {1, 2};
   if(!OnnxSetOutputShape(m_onnxHandle, 2, regShape))
   {
      Print("[GRU ADVANCED CRITICAL] OnnxSetOutputShape 2 failed. Error: " + IntegerToString(GetLastError()));
      return false;
   }

   m_initialized = true;
   PrintFormat("[GRU ADVANCED INFO] Initialized: %s with 108 features.", m_modelPath);
   return true;
}

//+------------------------------------------------------------------+
//| Scaling feature row using XM and XSD matrices                    |
//+------------------------------------------------------------------+
void CGRUAdvancedFilter::Std(double &row[])
{
   for(int k = 0; k < GRU_ADVANCED_FEATURES; k++)
   {
      double xsd = (GRU_ADV_XSD[k] > 0.0) ? GRU_ADV_XSD[k] : 1.0;
      double v = (row[k] - GRU_ADV_XM[k]) / xsd;
      row[k] = MathMax(-5.0, MathMin(5.0, v));
   }
}

//+------------------------------------------------------------------+
//| Build Synthetic DXY index basket rates                           |
//+------------------------------------------------------------------+
bool CGRUAdvancedFilter::BuildSyntheticDxy(MqlRates &dx[])
{
   MqlRates b0[], b1[], b2[], b3[], b4[], b5[];
   int nArr[6];
   nArr[0] = CopyRates(m_dxyPairs[0], PERIOD_M5, 0, 3000, b0);
   nArr[1] = CopyRates(m_dxyPairs[1], PERIOD_M5, 0, 3000, b1);
   nArr[2] = CopyRates(m_dxyPairs[2], PERIOD_M5, 0, 3000, b2);
   nArr[3] = CopyRates(m_dxyPairs[3], PERIOD_M5, 0, 3000, b3);
   nArr[4] = CopyRates(m_dxyPairs[4], PERIOD_M5, 0, 3000, b4);
   nArr[5] = CopyRates(m_dxyPairs[5], PERIOD_M5, 0, 3000, b5);

   int minN = 3000;
   for(int i = 0; i < 6; i++) minN = MathMin(minN, nArr[i]);
   if(minN < 200) return false;

   ArrayResize(dx, minN);
   for(int i = 0; i < minN; i++)
   {
      dx[i].time = b0[i].time;
      double eur = b0[i].close;
      double jpy = b1[i].close;
      double gbp = b2[i].close;
      double cad = b3[i].close;
      double sek = b4[i].close;
      double chf = b5[i].close;

      double val = 50.14348112 * MathPow(eur, -0.576) * MathPow(jpy, 0.136) *
                   MathPow(gbp, -0.119) * MathPow(cad, 0.091) *
                   MathPow(sek, 0.042) * MathPow(chf, 0.036);
      dx[i].close = val;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Build sequence window features (108 features across 96 bars)     |
//+------------------------------------------------------------------+
bool CGRUAdvancedFilter::BuildWindow()
{
   string sym = _Symbol;
   MqlRates m5[];
   int got = CopyRates(sym, PERIOD_M5, 1, 1500, m5);
   if(got < 96 + 250)
   {
      PrintFormat("[GRU ADVANCED] Not enough M5 history: %d", got);
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

   // 1. Core returns / momentum
   double logret[]; ArrayResize(logret, N);
   for(int i = 0; i < N; i++)
      logret[i] = (i >= 1) ? MathLog(c[i] / MathMax(c[i - 1], 1e-12)) : 0.0;

   // 2. Rolling volatility metrics
   double atr14[], atr100[];
   ArrayResize(atr14, N); ArrayResize(atr100, N);
   double tr[]; ArrayResize(tr, N);
   for(int i = 0; i < N; i++)
   {
      double pc = (i >= 1) ? c[i - 1] : c[i];
      tr[i] = MathMax(h[i] - l[i], MathMax(MathAbs(h[i] - pc), MathAbs(l[i] - pc)));
   }
   GRU_RollMean(tr, N, 14, atr14);
   GRU_RollMean(tr, N, 100, atr100);

   double atr_m[], atr_s[];
   ArrayResize(atr_m, N); ArrayResize(atr_s, N);
   GRU_RollMean(atr14, N, 100, atr_m);
   GRU_RollStd(atr14, N, 100, atr_s); 

   // Parkinson volatility
   double parkinson[]; ArrayResize(parkinson, N);
   {
      double logret_mean[]; ArrayResize(logret_mean, N);
      GRU_RollMean(logret, N, 14, logret_mean);
      double logret_var[]; ArrayResize(logret_var, N);
      GRU_RollStd(logret, N, 14, logret_var);
      for(int i = 0; i < N; i++)
         parkinson[i] = MathSqrt(MathPow(logret_var[i], 2) * 4.0 * MathLog(2.0));
   }

   // 3. Oscillators / EMAs
   double rsi[]; ArrayResize(rsi, N);
   {
      double gain[], loss[];
      ArrayResize(gain, N); ArrayResize(loss, N);
      for(int i = 0; i < N; i++)
      {
         double diff = (i >= 1) ? c[i] - c[i - 1] : 0.0;
         gain[i] = diff > 0.0 ? diff : 0.0;
         loss[i] = diff < 0.0 ? -diff : 0.0;
      }
      double gain_ma[], loss_ma[];
      ArrayResize(gain_ma, N); ArrayResize(loss_ma, N);
      GRU_RollMean(gain, N, 14, gain_ma);
      GRU_RollMean(loss, N, 14, loss_ma);
      for(int i = 0; i < N; i++)
      {
         double rs = loss_ma[i] > 1e-12 ? gain_ma[i] / loss_ma[i] : 1e12;
         rsi[i] = 100.0 - 100.0 / (1.0 + rs);
      }
   }

   double macd_fast[], macd_slow[], macd_hist[];
   ArrayResize(macd_fast, N); ArrayResize(macd_slow, N); ArrayResize(macd_hist, N);
   GRU_EMA(c, N, 12, macd_fast);
   GRU_EMA(c, N, 26, macd_slow);
   for(int i = 0; i < N; i++) macd_hist[i] = macd_fast[i] - macd_slow[i];

   double macd_sig[], macd_hist_diff[];
   ArrayResize(macd_sig, N); ArrayResize(macd_hist_diff, N);
   GRU_EMA(macd_hist, N, 9, macd_sig);
   for(int i = 0; i < N; i++) macd_hist_diff[i] = macd_hist[i] - macd_sig[i];

   double c_std50[]; ArrayResize(c_std50, N);
   {
      double c_mean50[]; ArrayResize(c_mean50, N);
      GRU_RollMean(c, N, 50, c_mean50);
      GRU_RollStd(c, N, 50, c_std50);
   }

   double ema20[], ema50[], ema200[];
   GRU_EMA(c, N, 20, ema20);
   GRU_EMA(c, N, 50, ema50);
   GRU_EMA(c, N, 200, ema200);

   // VWAP 20
   double vwap20[]; ArrayResize(vwap20, N);
   {
      double sTv = 0.0, sV = 0.0;
      for(int i = 0; i < N; i++)
      {
         double tp = (h[i] + l[i] + c[i]) / 3.0;
         sTv += tp * v[i]; sV += v[i];
         if(i >= 20) { int j = i - 20; double tpj = (h[j] + l[j] + c[j]) / 3.0; sTv -= tpj * v[j]; sV -= v[j]; }
         vwap20[i] = (i >= 19 && sV > 0.0) ? sTv / sV : c[i];
      }
   }

   // 4. SMC indicators
   double ob_bull[], ob_bear[];
   ArrayResize(ob_bull, N); ArrayResize(ob_bear, N);
   double fvg_bull[], fvg_bear[], mss[];
   ArrayResize(fvg_bull, N); ArrayResize(fvg_bear, N); ArrayResize(mss, N);
   ArrayInitialize(ob_bull, 0.0); ArrayInitialize(ob_bear, 0.0);
   ArrayInitialize(fvg_bull, 0.0); ArrayInitialize(fvg_bear, 0.0);
   ArrayInitialize(mss, 0.0);

   for(int i = 2; i < N; i++)
   {
      double min_low = l[i - 1];
      for(int k = i - 1; k >= MathMax(0, i - 24); k--)
      {
         if(c[k] < o[k] && l[k] < min_low) min_low = l[k];
      }
      ob_bull[i] = min_low;

      double max_high = h[i - 1];
      for(int k = i - 1; k >= MathMax(0, i - 24); k--)
      {
         if(c[k] > o[k] && h[k] > max_high) max_high = h[k];
      }
      ob_bear[i] = max_high;

      if(l[i - 1] > h[i - 2] && c[i] > l[i - 1]) fvg_bull[i] = 1.0;
      if(h[i - 1] < l[i - 2] && c[i] < h[i - 1]) fvg_bear[i] = 1.0;

      double hh = h[i - 1];
      double ll = l[i - 1];
      for(int k = i - 2; k >= i - 5; k--)
      {
         if(h[k] > hh) hh = h[k];
         if(l[k] < ll) ll = l[k];
      }
      if(c[i] > hh || c[i] < ll) mss[i] = 1.0;
   }

   // 5. Multi-timeframe H1 / H4 / D1
   MqlRates h1[];
   int n1 = CopyRates(sym, PERIOD_H1, 1, 240, h1);
   ArraySetAsSeries(h1, true);
   
   MqlRates h4[];
   int n4 = CopyRates(sym, PERIOD_H4, 1, 120, h4);
   ArraySetAsSeries(h4, true);
   
    MqlRates d1[];
    int n2 = CopyRates(sym, PERIOD_D1, 1, 80, d1);
    ArraySetAsSeries(d1, true);

    // Derived MTF features from real H1/H4/D1 closes
    double h1_close[]; ArrayResize(h1_close, n1); for(int q = 0; q < n1; q++) h1_close[q] = h1[q].close;
    double h1_zc[], h1_es[], h1_de[];
    ArrayResize(h1_zc, n1); ArrayResize(h1_es, n1); ArrayResize(h1_de, n1);
    MTFDerived(h1_close, n1, h1_zc, h1_es, h1_de);

    double h4_close[]; ArrayResize(h4_close, n4); for(int q = 0; q < n4; q++) h4_close[q] = h4[q].close;
    double h4_zc[], h4_es[], h4_de[];
    ArrayResize(h4_zc, n4); ArrayResize(h4_es, n4); ArrayResize(h4_de, n4);
    MTFDerived(h4_close, n4, h4_zc, h4_es, h4_de);

    double d1_close[]; ArrayResize(d1_close, n2); for(int q = 0; q < n2; q++) d1_close[q] = d1[q].close;
    double d1_zc[], d1_es[], d1_de[];
    ArrayResize(d1_zc, n2); ArrayResize(d1_es, n2); ArrayResize(d1_de, n2);
    MTFDerived(d1_close, n2, d1_zc, d1_es, d1_de);

   // 6. Real order-flow aggregates
   datetime seq_times[]; ArrayResize(seq_times, 96);
   int base = N - 96;
   for(int r = 0; r < 96; r++)
      seq_times[r] = t[base + r];
      
   double of_buy_vol[], of_sell_vol[], of_trade_count[], of_total_vol[], of_avg_trade[], of_max_trade[], of_imbalance[];
   bool has_of = GetLiveOrderFlow(seq_times, of_buy_vol, of_sell_vol, of_trade_count, of_total_vol, of_avg_trade, of_max_trade, of_imbalance);

   // Rolling volume indicators
   double vMean[]; ArrayResize(vMean, N);
   GRU_RollMean(v, N, 20, vMean);

   // Compute rolling z-score and volatility indicator arrays outside the loop (for O(N) instead of O(N^2))
   double c_mean20[], c_std20[], h_mean20[], h_std20[], l_mean20[], l_std20[];
   ArrayResize(c_mean20, N); ArrayResize(c_std20, N);
   ArrayResize(h_mean20, N); ArrayResize(h_std20, N);
   ArrayResize(l_mean20, N); ArrayResize(l_std20, N);
   GRU_RollMean(c, N, 20, c_mean20); GRU_RollStd(c, N, 20, c_std20);
   GRU_RollMean(h, N, 20, h_mean20); GRU_RollStd(h, N, 20, h_std20);
   GRU_RollMean(l, N, 20, l_mean20); GRU_RollStd(l, N, 20, l_std20);

   double c_mean50[], h_mean50[], h_std50[], l_mean50[], l_std50[];
   ArrayResize(c_mean50, N);
   ArrayResize(h_mean50, N); ArrayResize(h_std50, N);
   ArrayResize(l_mean50, N); ArrayResize(l_std50, N);
   GRU_RollMean(c, N, 50, c_mean50);
   GRU_RollMean(h, N, 50, h_mean50); GRU_RollStd(h, N, 50, h_std50);
   GRU_RollMean(l, N, 50, l_mean50); GRU_RollStd(l, N, 50, l_std50);

   double c_mean100[], c_std100[], h_mean100[], h_std100[], l_mean100[], l_std100[];
   ArrayResize(c_mean100, N); ArrayResize(c_std100, N);
   ArrayResize(h_mean100, N); ArrayResize(h_std100, N);
   ArrayResize(l_mean100, N); ArrayResize(l_std100, N);
   GRU_RollMean(c, N, 100, c_mean100); GRU_RollStd(c, N, 100, c_std100);
   GRU_RollMean(h, N, 100, h_mean100); GRU_RollStd(h, N, 100, h_std100);
   GRU_RollMean(l, N, 100, l_mean100); GRU_RollStd(l, N, 100, l_std100);

   double logret_mean12[], logret_std12[];
   double logret_mean24[], logret_std24[];
   double logret_mean48[], logret_std48[];
   double logret_mean96[], logret_std96[];
   ArrayResize(logret_mean12, N); ArrayResize(logret_std12, N);
   ArrayResize(logret_mean24, N); ArrayResize(logret_std24, N);
   ArrayResize(logret_mean48, N); ArrayResize(logret_std48, N);
   ArrayResize(logret_mean96, N); ArrayResize(logret_std96, N);
   GRU_RollMean(logret, N, 12, logret_mean12); GRU_RollStd(logret, N, 12, logret_std12);
   GRU_RollMean(logret, N, 24, logret_mean24); GRU_RollStd(logret, N, 24, logret_std24);
   GRU_RollMean(logret, N, 48, logret_mean48); GRU_RollStd(logret, N, 48, logret_std48);
    GRU_RollMean(logret, N, 96, logret_mean96); GRU_RollStd(logret, N, 96, logret_std96);

    // --- REAL features mirroring training features_advanced.py (was hard-coded 0) ---
    double skew50[], kurt50[];
    ArrayResize(skew50, N); ArrayResize(kurt50, N);
    GRU_RollSkewKurt(logret, N, 50, skew50, kurt50);

    double adx_v[];
    ArrayResize(adx_v, N);
    GRU_ADX(h, l, c, N, 14, adx_v);

    double tr_sum14[], hhll14[];
    ArrayResize(tr_sum14, N); ArrayResize(hhll14, N);
    GRU_RollSum(tr, N, 14, tr_sum14);
    for(int i = 0; i < N; i++)
    {
       if(i < 13) { hhll14[i] = 0.0; continue; }
       double mx = h[i], mn = l[i];
       for(int k = i - 13; k <= i; k++) { if(h[k] > mx) mx = h[k]; if(l[k] < mn) mn = l[k]; }
       hhll14[i] = mx - mn;
    }
    double chop_v[];
    ArrayResize(chop_v, N);
    for(int i = 0; i < N; i++)
    {
       if(i < 13) { chop_v[i] = 50.0; continue; }
       double num = MathLog10(tr_sum14[i] / 14.0 + 1e-9);
       double den = MathLog10(hhll14[i] + 1e-6);
       den = (MathAbs(den) < 0.05) ? (den >= 0.0 ? 0.05 : -0.05) : den;
       double ch = 100.0 * num / den;
       chop_v[i] = MathMax(-200.0, MathMin(200.0, ch));
    }

    // 7. Synthetic DXY
    MqlRates dx[];
    bool has_dxy = BuildSyntheticDxy(dx);
    ArraySetAsSeries(dx, true);
    int mD = ArraySize(dx);

    // DXY derived features (atr_norm, zclose20/50) from synthetic DXY series
    double dx_close[], dx_high[], dx_low[], dx_tr[];
    ArrayResize(dx_close, mD); ArrayResize(dx_high, mD); ArrayResize(dx_low, mD); ArrayResize(dx_tr, mD);
    for(int q = 0; q < mD; q++) { dx_close[q] = dx[q].close; dx_high[q] = dx[q].high; dx_low[q] = dx[q].low; }
    if(mD > 0) GRU_TR(dx_high, dx_low, dx_close, mD, dx_tr);
    double dx_atr14[]; ArrayResize(dx_atr14, mD);
    if(mD > 0) GRU_RollMean(dx_tr, mD, 14, dx_atr14);
    double dx_z20[], dx_z50[]; ArrayResize(dx_z20, mD); ArrayResize(dx_z50, mD);
    if(mD > 0) { GRU_Zscore(dx_close, mD, 20, dx_z20); GRU_Zscore(dx_close, mD, 50, dx_z50); }

   // Map all features into sequence window
    int ih = 0, iq = 0, id = 0, jd = 0;
    double of_med = 0.0;
    if(has_of)
    {
       double tmp[]; ArrayResize(tmp, 96);
       for(int r = 0; r < 96; r++) tmp[r] = of_trade_count[r];
       ArraySort(tmp);
       of_med = tmp[48];
    }
    for(int r = 0; r < 96; r++)
   {
      int i = base + r;
      datetime T = t[i];

      // Align MTF rates by timestamp
      while(ih + 1 < n1 && (h1[ih + 1].time + 3600) <= T) ih++;
      while(iq + 1 < n4 && (h4[iq + 1].time + 14400) <= T) iq++;
      while(id + 1 < n2 && (d1[id + 1].time + 86400) <= T) id++;
      while(jd + 1 < mD && dx[jd + 1].time <= T) jd++;

      int hour = (int)((T / 3600) % 24);
      int dow  = (int)(((T / 86400) + 3) % 7);

      double f[GRU_ADVANCED_FEATURES];
      ArrayInitialize(f, 0.0);

      double rng = MathMax(h[i] - l[i], 1e-9);
      
      // 0 - 5: ret1..ret96
      f[0] = (i >= 1)  ? c[i]/MathMax(c[i-1], 1e-12) - 1.0 : 0.0;
      f[1] = (i >= 5)  ? c[i]/MathMax(c[i-5], 1e-12) - 1.0 : 0.0;
      f[2] = (i >= 12) ? c[i]/MathMax(c[i-12], 1e-12) - 1.0 : 0.0;
      f[3] = (i >= 24) ? c[i]/MathMax(c[i-24], 1e-12) - 1.0 : 0.0;
      f[4] = (i >= 48) ? c[i]/MathMax(c[i-48], 1e-12) - 1.0 : 0.0;
      f[5] = (i >= 96) ? c[i]/MathMax(c[i-96], 1e-12) - 1.0 : 0.0;

      // 6 - 8: mom6..mom24
      f[6] = (i >= 6)  ? c[i]/MathMax(c[i-6], 1e-12) - 1.0 : 0.0;
      f[7] = (i >= 12) ? c[i]/MathMax(c[i-12], 1e-12) - 1.0 : 0.0;
      f[8] = (i >= 24) ? c[i]/MathMax(c[i-24], 1e-12) - 1.0 : 0.0;

      // 9: accel
      f[9] = (i >= 2) ? (c[i] - c[i-1]) - (c[i-1] - c[i-2]) : 0.0;
      
       // 10 - 11: skew/kurt (REAL, rolling 50 of M5 logret)
       f[10] = skew50[i]; f[11] = kurt50[i];

      // 12 - 20: zclose/zhigh/zlow
      f[12] = (c_std20[i] > 1e-8) ? (c[i] - c_mean20[i]) / c_std20[i] : 0.0;
      f[13] = (h_std20[i] > 1e-8) ? (h[i] - h_mean20[i]) / h_std20[i] : 0.0;
      f[14] = (l_std20[i] > 1e-8) ? (l[i] - l_mean20[i]) / l_std20[i] : 0.0;

      f[15] = (c_std50[i] > 1e-8) ? (c[i] - c_mean50[i]) / c_std50[i] : 0.0;
      f[16] = (h_std50[i] > 1e-8) ? (h[i] - h_mean50[i]) / h_std50[i] : 0.0;
      f[17] = (l_std50[i] > 1e-8) ? (l[i] - l_mean50[i]) / l_std50[i] : 0.0;

      f[18] = (c_std100[i] > 1e-8) ? (c[i] - c_mean100[i]) / c_std100[i] : 0.0;
      f[19] = (h_std100[i] > 1e-8) ? (h[i] - h_mean100[i]) / h_std100[i] : 0.0;
      f[20] = (l_std100[i] > 1e-8) ? (l[i] - l_mean100[i]) / l_std100[i] : 0.0;

      // 21 - 22: atr_ratio, atr_norm
      f[21] = atr100[i] > 0.0 ? atr14[i] / atr100[i] : 0.0;
      f[22] = atr14[i] / MathMax(c[i], 1e-12);

      // 23 - 26: rv12..rv96
      f[23] = logret_std12[i];
      f[24] = logret_std24[i];
      f[25] = logret_std48[i];
      f[26] = logret_std96[i];

      // 27: vol_cone
      f[27] = (f[26] > 1e-8) ? f[24] / f[26] : 0.0;

      // 28: vol_z
      f[28] = atr_s[i] > 1e-8 ? (atr14[i] - atr_m[i]) / atr_s[i] : 0.0;

      // 29: parkinson
      f[29] = parkinson[i];

      // 30 - 31: rsi, rsi_slope
      f[30] = rsi[i];
      f[31] = (i >= 5) ? rsi[i] - rsi[i-5] : 0.0;

      // 32 - 33: macd_hist_norm, macd_slope
      f[32] = c_std50[i] > 1e-8 ? macd_hist[i] / c_std50[i] : 0.0;
      f[33] = (i >= 5) ? macd_hist[i] - macd_hist[i-5] : 0.0;

      // 34: stoch
      double min_l14 = l[i];
      double max_h14 = h[i];
      for(int k = i - 1; k >= MathMax(0, i - 13); k--)
      {
         if(l[k] < min_l14) min_l14 = l[k];
         if(h[k] > max_h14) max_h14 = h[k];
      }
      f[34] = (max_h14 - min_l14) > 1e-9 ? (c[i] - min_l14) / (max_h14 - min_l14) : 0.5;

      // 35 - 40: dist_ema / slopes
      f[35] = (c[i] - ema20[i]) / MathMax(ema20[i]*1e-3, 1e-12);
      f[36] = (i >= 5) ? (ema20[i] - ema20[i-5]) / MathMax(ema20[i-5]*1e-3, 1e-12) : 0.0;
      f[37] = (c[i] - ema50[i]) / MathMax(ema50[i]*1e-3, 1e-12);
      f[38] = (i >= 5) ? (ema50[i] - ema50[i-5]) / MathMax(ema50[i-5]*1e-3, 1e-12) : 0.0;
      f[39] = (c[i] - ema200[i]) / MathMax(ema200[i]*1e-3, 1e-12);
      f[40] = (i >= 5) ? (ema200[i] - ema200[i-5]) / MathMax(ema200[i-5]*1e-3, 1e-12) : 0.0;

      // 41: dist_vwap20
      f[41] = (c[i] - vwap20[i]) / MathMax(vwap20[i]*1e-3, 1e-12);

      // 42 - 47: candles shape
      f[42] = MathAbs(c[i] - o[i]) / rng;
      f[43] = (h[i] - MathMax(o[i], c[i])) / rng;
      f[44] = (MathMin(o[i], c[i]) - l[i]) / rng;
      f[45] = (c[i] - l[i]) / rng;
      f[46] = (c[i] - l[i]) / rng;
      f[47] = (h[i] - c[i]) / rng;

      // 48 - 50: delta / pressure
      f[48] = f[46] - f[47];
      double d_sum = 0;
      for(int k = i; k >= MathMax(0, i-11); k--)
      {
         double dk = ((c[k]-l[k]) - (h[k]-c[k])) / MathMax(h[k]-l[k], 1e-9);
         d_sum += dk;
      }
      f[49] = d_sum / 12.0;
      f[50] = (i >= 5) ? f[48] - ( (c[i-5]-l[i-5]) - (h[i-5]-c[i-5]) )/MathMax(h[i-5]-l[i-5], 1e-9) : 0.0;

      // 51 - 54: support / resistance
      double min_l24 = l[i], max_h24 = h[i];
      for(int k = i - 1; k >= MathMax(0, i - 23); k--)
      {
         if(l[k] < min_l24) min_l24 = l[k];
         if(h[k] > max_h24) max_h24 = h[k];
      }
      f[51] = (c[i] - min_l24) / MathMax(c[i], 1e-12);
      f[52] = (max_h24 - c[i]) / MathMax(c[i], 1e-12);

      double min_l96 = l[i], max_h96 = h[i];
      for(int k = i - 1; k >= MathMax(0, i - 95); k--)
      {
         if(l[k] < min_l96) min_l96 = l[k];
         if(h[k] > max_h96) max_h96 = h[k];
      }
      f[53] = (c[i] - min_l96) / MathMax(c[i], 1e-12);
      f[54] = (max_h96 - c[i]) / MathMax(c[i], 1e-12);

      // 55 - 56: SMC orderblocks
      f[55] = (c[i] - ob_bull[i]) / MathMax(c[i], 1e-12);
      f[56] = (ob_bear[i] - c[i]) / MathMax(c[i], 1e-12);

      // 57 - 58: FVG
      f[57] = fvg_bull[i];
      f[58] = fvg_bear[i];

      // 59: MSS
      f[59] = mss[i];

      // 60 - 71: H1, H4, D1 multi-timeframe
       if(ih < n1)
       {
          int ihp = (ih > 0) ? ih - 1 : ih;
          f[60] = h1[ihp].open > 0.0 ? h1[ihp].close / h1[ihp].open - 1.0 : 0.0;
          f[61] = h1_zc[ihp];
          f[62] = h1_es[ihp];
          f[63] = h1_de[ihp];
       }
       if(iq < n4)
       {
          int iqp = (iq > 0) ? iq - 1 : iq;
          f[64] = h4[iqp].open > 0.0 ? h4[iqp].close / h4[iqp].open - 1.0 : 0.0;
          f[65] = h4_zc[iqp];
          f[66] = h4_es[iqp];
          f[67] = h4_de[iqp];
       }
       if(id < n2)
       {
          int idp = (id > 0) ? id - 1 : id;
          f[68] = d1[idp].open > 0.0 ? d1[idp].close / d1[idp].open - 1.0 : 0.0;
          f[69] = d1_zc[idp];
          f[70] = d1_es[idp];
          f[71] = d1_de[idp];
       }

       // 72 - 76: Chop, ADX, regime trend (REAL)
       f[72] = chop_v[i];
       f[73] = adx_v[i];
       f[74] = 1.0 / (1.0 + MathExp(-(adx_v[i] - 20.0) / 5.0));
       f[75] = 1.0 - f[74];
       f[76] = (f[28] > 0.5) ? 1.0 : 0.0;

      // 77 - 78: Vol ratio, rel sess vol
      f[77] = (vMean[i] > 1e-8) ? v[i] / vMean[i] : 1.0;
      f[78] = f[77];

      // 79 - 88: REAL ORDERFLOW
      if(has_of)
      {
         f[79] = of_buy_vol[r];
         f[80] = of_sell_vol[r];
         f[81] = of_trade_count[r];
         f[82] = of_total_vol[r];
         f[83] = of_avg_trade[r];
         f[84] = of_max_trade[r];
         f[85] = of_imbalance[r];
         
         double of_imb_mean20 = 0, of_imb_std20 = 0;
         double of_imb_sum = 0;
         int of_c = 0;
         for(int k = r; k >= MathMax(0, r-19); k--)
         {
            of_imb_sum += of_imbalance[k];
            of_c++;
         }
         of_imb_mean20 = of_imb_sum / MathMax(of_c, 1);
         double of_imb_var = 0;
         for(int k = r; k >= MathMax(0, r-19); k--)
            of_imb_var += MathPow(of_imbalance[k] - of_imb_mean20, 2);
         of_imb_std20 = MathSqrt(of_imb_var / MathMax(of_c - 1, 1) + 1e-8);
         f[86] = (of_imbalance[r] - of_imb_mean20) / MathMax(of_imb_std20, 1e-8);
         
          f[87] = (of_buy_vol[r] + of_sell_vol[r]) > 0.0 ? of_buy_vol[r] / (of_buy_vol[r] + of_sell_vol[r]) : 0.5;
          f[88] = (of_trade_count[r] > of_med) ? 1.0 : 0.0;
       }
      else
      {
         f[79] = f[80] = f[81] = f[82] = f[83] = f[84] = f[85] = 0.0;
         f[86] = 0.0; f[87] = 0.5; f[88] = 0.0;
      }

      // 89 - 96: Time & session
      f[89] = MathSin(2.0 * M_PI * hour / 24.0);
      f[90] = MathCos(2.0 * M_PI * hour / 24.0);
      f[91] = MathSin(2.0 * M_PI * dow / 7.0);
      f[92] = MathCos(2.0 * M_PI * dow / 7.0);
      f[93] = (hour >= 0 && hour < 7) ? 1.0 : 0.0;
      f[94] = (hour >= 7 && hour < 13) ? 1.0 : 0.0;
      f[95] = (hour >= 13 && hour < 22) ? 1.0 : 0.0;
      f[96] = (hour >= 12 && hour < 15) ? 1.0 : 0.0;

      // 97 - 107: DXY features
       if(has_dxy && jd < mD)
       {
          f[97] = (dx_close[jd] > 0.0) ? dx_atr14[jd] / dx_close[jd] : 0.0;
          f[98] = (jd >= 1) ? dx[jd].close / dx[jd - 1].close - 1.0 : 0.0;
          f[99] = (jd >= 12) ? dx[jd].close / dx[jd - 12].close - 1.0 : 0.0;
          f[100] = (jd >= 150) ? dx_close[jd] / dx_close[jd - 150] - 1.0 : 0.0;
          f[101] = (jd >= 24) ? dx[jd].close / dx[jd - 24].close - 1.0 : 0.0;
          f[102] = (jd >= 48) ? dx[jd].close / dx[jd - 48].close - 1.0 : 0.0;
          f[103] = (jd >= 5) ? dx[jd].close / dx[jd - 5].close - 1.0 : 0.0;
          f[104] = (jd >= 96) ? dx[jd].close / dx[jd - 96].close - 1.0 : 0.0;
          f[105] = dx_z20[jd];
          f[106] = dx_z50[jd];
          f[107] = 1.0;
       }
      else
      {
         f[107] = 0.0;
      }

      Std(f);
      for(int k = 0; k < GRU_ADVANCED_FEATURES; k++)
         m_inputData[r * GRU_ADVANCED_FEATURES + k] = (float)f[k];
   }

   return true;
}

//+------------------------------------------------------------------+
//| Run inference on the loaded multi-output model                   |
//+------------------------------------------------------------------+
bool CGRUAdvancedFilter::RunInference(float &dirOutputs[], float &retOutputs[], float &regOutputs[])
{
   if(!m_initialized || m_onnxHandle == INVALID_HANDLE)
   {
      Print("[GRU ADVANCED ERROR] Model not initialized.");
      return false;
   }

   ResetLastError();
   if(!OnnxRun(m_onnxHandle, ONNX_NO_CONVERSION, m_inputData, dirOutputs, retOutputs, regOutputs))
   {
      Print("[GRU ADVANCED ERROR] OnnxRun failed. Error code: " + IntegerToString(GetLastError()));
      return false;
   }
   
   return true;
}
