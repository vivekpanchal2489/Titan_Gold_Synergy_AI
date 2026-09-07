@echo off
echo ===================================================================
echo   Titan Gold Synergy AI - Plug and Play Installer for Windows / VPS
echo ===================================================================
echo.
set /p MT5_DATA_DIR="Enter your MetaTrader 5 Data Directory (e.g. C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\<hash>): "

if not exist "%MT5_DATA_DIR%" (
    echo [ERROR] The directory "%MT5_DATA_DIR%" does not exist.
    pause
    exit /b 1
)

echo [1/3] Copying MQL5 Experts...
xcopy /E /I /Y "..\MQL5\Experts\*" "%MT5_DATA_DIR%\MQL5\Experts\"

echo [2/3] Copying MQL5 Include files...
xcopy /E /I /Y "..\MQL5\Include\*" "%MT5_DATA_DIR%\MQL5\Include\"

echo [3/3] Copying Neural Network ONNX Models...
xcopy /E /I /Y "..\MQL5\Files\*" "%MT5_DATA_DIR%\MQL5\Files\"

echo.
echo ===================================================================
echo [SUCCESS] Titan Gold Synergy AI installed successfully!
echo Instructions:
echo   1. Restart or refresh MetaTrader 5 (Navigator -> Right click Experts -> Refresh).
echo   2. Open XAUUSD M5 chart.
echo   3. Drag 'Titan_Gold_Synergy_AI' or 'GoldEngine_Sentinel' onto the chart.
echo   4. Enable 'Allow Algo Trading' and 'Allow WebRequest'.
echo ===================================================================
pause
