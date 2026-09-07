#!/bin/bash
WINE_PREFIX="/Users/vivekpanchal/Library/Application Support/net.metaquotes.wine.metatrader5"
WINE_EXE="/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine64"
EDITOR_EXE="C:\\Program Files\\MetaTrader 5\\metaeditor64.exe"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Staging Titan Gold Synergy AI Package to MT5 Wine directory ==="
mkdir -p "$WINE_PREFIX/drive_c/Program Files/MetaTrader 5/MQL5/Include"
mkdir -p "$WINE_PREFIX/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
mkdir -p "$WINE_PREFIX/drive_c/Program Files/MetaTrader 5/MQL5/Files"

cp -f "$SCRIPT_DIR"/MQL5/Include/*.mqh "$WINE_PREFIX/drive_c/Program Files/MetaTrader 5/MQL5/Include/"
cp -f "$SCRIPT_DIR"/MQL5/Experts/*.mq5 "$WINE_PREFIX/drive_c/Program Files/MetaTrader 5/MQL5/Experts/"
cp -f "$SCRIPT_DIR"/MQL5/Files/* "$WINE_PREFIX/drive_c/Program Files/MetaTrader 5/MQL5/Files/"

TARGET_SYNERGY="C:\\Program Files\\MetaTrader 5\\MQL5\\Experts\\Titan_Gold_Synergy_AI.mq5"
echo "=== Compiling Titan_Gold_Synergy_AI.mq5 via Wine MetaEditor64 ==="
env WINEPREFIX="$WINE_PREFIX" "$WINE_EXE" "$EDITOR_EXE" /compile:"$TARGET_SYNERGY" /log

LOG_FILE="$WINE_PREFIX/drive_c/Program Files/MetaTrader 5/MQL5/Experts/Titan_Gold_Synergy_AI.log"
if [ -f "$LOG_FILE" ]; then
    echo "--- Titan_Gold_Synergy_AI Compilation Result ---"
    iconv -f utf-16 -t utf-8 "$LOG_FILE"
    cp -f "$WINE_PREFIX/drive_c/Program Files/MetaTrader 5/MQL5/Experts/Titan_Gold_Synergy_AI.ex5" "$SCRIPT_DIR/MQL5/Experts/" 2>/dev/null
fi

TARGET_SENTINEL="C:\\Program Files\\MetaTrader 5\\MQL5\\Experts\\GoldEngine_Sentinel.mq5"
echo "=== Compiling GoldEngine_Sentinel.mq5 via Wine MetaEditor64 ==="
env WINEPREFIX="$WINE_PREFIX" "$WINE_EXE" "$EDITOR_EXE" /compile:"$TARGET_SENTINEL" /log

LOG_FILE2="$WINE_PREFIX/drive_c/Program Files/MetaTrader 5/MQL5/Experts/GoldEngine_Sentinel.log"
if [ -f "$LOG_FILE2" ]; then
    echo "--- GoldEngine_Sentinel Compilation Result ---"
    iconv -f utf-16 -t utf-8 "$LOG_FILE2"
    cp -f "$WINE_PREFIX/drive_c/Program Files/MetaTrader 5/MQL5/Experts/GoldEngine_Sentinel.ex5" "$SCRIPT_DIR/MQL5/Experts/" 2>/dev/null
fi
