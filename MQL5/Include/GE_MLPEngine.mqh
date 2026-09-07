//+------------------------------------------------------------------+
//|                                              GE_MLPEngine.mqh    |
//|               Lightweight 76-Feature Neural Inference Engine     |
//|             Zero-Latency C++ ONNX Runtime for MT5 (<0.1ms)       |
//+------------------------------------------------------------------+
#ifndef GE_MLPENGINE_MQH
#define GE_MLPENGINE_MQH

#define MLP_INPUT_SIZE  76
#define MLP_OUTPUT_SIZE 3

class CGoldAIMLPEngine
{
private:
   long     m_onnxHandle;
   string   m_modelPath;
   bool     m_initialized;
   
   float    m_inputBuffer[MLP_INPUT_SIZE];
   float    m_outputBuffer[MLP_OUTPUT_SIZE];
   
   float    m_lastProbBull;
   float    m_lastProbNeu;
   float    m_lastProbBear;

public:
   CGoldAIMLPEngine() : m_onnxHandle(INVALID_HANDLE), m_modelPath("gold_mlp_ai.onnx"), m_initialized(false),
      m_lastProbBull(0.0f), m_lastProbNeu(0.0f), m_lastProbBear(0.0f)
   {
      ArrayInitialize(m_inputBuffer, 0.0f);
      ArrayInitialize(m_outputBuffer, 0.0f);
   }
   
   ~CGoldAIMLPEngine() { Release(); }
   
   bool Initialize(string modelFileName = "gold_mlp_ai.onnx")
   {
      m_modelPath = modelFileName;
      
      m_onnxHandle = OnnxCreate(m_modelPath, ONNX_DEFAULT);
      if(m_onnxHandle == INVALID_HANDLE)
      {
         PrintFormat("[GoldAI MLP ONNX] WARNING: Failed to create ONNX session from '%s'. Error: %d", m_modelPath, GetLastError());
         m_initialized = false;
         return false;
      }
      
      const long input_shape[]  = {1, MLP_INPUT_SIZE};
      const long output_shape[] = {1, MLP_OUTPUT_SIZE};
      
      OnnxSetInputShape(m_onnxHandle, 0, input_shape);
      OnnxSetOutputShape(m_onnxHandle, 0, output_shape);
      
      m_initialized = true;
      PrintFormat("[GoldAI MLP ONNX] SUCCESS: Loaded '%s' (Input 1x%d -> Output 1x%d).", m_modelPath, MLP_INPUT_SIZE, MLP_OUTPUT_SIZE);
      return true;
   }

   bool Init(string modelFileName = "gold_mlp_ai.onnx")
   {
      return Initialize(modelFileName);
   }
   
   void Release()
   {
      if(m_onnxHandle != INVALID_HANDLE)
      {
         OnnxRelease(m_onnxHandle);
         m_onnxHandle = INVALID_HANDLE;
      }
      m_initialized = false;
   }

   void Shutdown() { Release(); }
   bool IsInitialized() const { return m_initialized; }

   bool Predict(const float &features[], float &pBull, float &pNeu, float &pBear)
   {
      pBull = 0.0f; pNeu = 0.0f; pBear = 0.0f;
      if(!m_initialized || m_onnxHandle == INVALID_HANDLE)
         return false;
         
      if(ArraySize(features) < MLP_INPUT_SIZE)
         return false;
      
      for(int i = 0; i < MLP_INPUT_SIZE; i++)
         m_inputBuffer[i] = features[i];
         
      if(!OnnxRun(m_onnxHandle, ONNX_NO_CONVERSION, m_inputBuffer, m_outputBuffer))
      {
         PrintFormat("[GoldAI MLP ONNX] Inference execution failed. Error: %d", GetLastError());
         return false;
      }
      
      pBull = m_outputBuffer[0];
      pNeu  = m_outputBuffer[1];
      pBear = m_outputBuffer[2];
      
      m_lastProbBull = pBull;
      m_lastProbNeu  = pNeu;
      m_lastProbBear = pBear;
      
      return true;
   }
};

#endif // GE_MLPENGINE_MQH
