#!/bin/bash
echo "==================================================================="
echo "  Titan Gold Synergy AI - Plug and Play Installer for Mac / Linux  "
echo "==================================================================="

DEFAULT_MAC_PATH="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5"

if [ -d "$DEFAULT_MAC_PATH" ]; then
    TARGET_DIR="$DEFAULT_MAC_PATH"
else
    read -p "Enter your MetaTrader 5 Data Directory: " TARGET_DIR
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[1/3] Copying MQL5 Experts..."
mkdir -p "$TARGET_DIR/MQL5/Experts"
cp -f "$SCRIPT_DIR"/MQL5/Experts/* "$TARGET_DIR/MQL5/Experts/"

echo "[2/3] Copying MQL5 Include files..."
mkdir -p "$TARGET_DIR/MQL5/Include"
cp -f "$SCRIPT_DIR"/MQL5/Include/* "$TARGET_DIR/MQL5/Include/"

echo "[3/3] Copying Neural Network ONNX Models..."
mkdir -p "$TARGET_DIR/MQL5/Files"
cp -f "$SCRIPT_DIR"/MQL5/Files/* "$TARGET_DIR/MQL5/Files/"

echo "==================================================================="
echo "[SUCCESS] Installed Titan Gold Synergy AI into $TARGET_DIR"
echo "==================================================================="
