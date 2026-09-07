#!/usr/bin/env python3
"""
test_dual_engine_threshold_sweep.py
===================================
Sweeps thresholds to find the highest-quality, institutional-grade
sweet spot for:
  - Solo LightGBM Threshold
  - Solo MLP Threshold
  - Dual-Engine Synergy Multiplier
"""

import os
import sys
import numpy as np
import pandas as pd
import lightgbm as lgb
from sklearn.neural_network import MLPClassifier

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(BASE_DIR, "data")
INPUT_PARQUET = os.path.join(DATA_DIR, "dataset_76_genuine.parquet")

df = pd.read_parquet(INPUT_PARQUET)
feature_cols = [c for c in df.columns if c not in ["time", "target"]]

split_idx = int(len(df) * 0.80)
embargo = 24

train_df = df.iloc[:split_idx]
test_df = df.iloc[split_idx + embargo:].copy()

X_train = train_df[feature_cols].values.astype(np.float32)
y_train = train_df["target"].values.astype(np.int32)
X_test = test_df[feature_cols].values.astype(np.float32)
y_test = test_df["target"].values.astype(np.int32)

# Train LGBM
lgb_params = {
    'objective': 'multiclass',
    'num_class': 3,
    'metric': 'multi_logloss',
    'boosting_type': 'gbdt',
    'learning_rate': 0.05,
    'num_leaves': 31,
    'feature_fraction': 0.8,
    'verbose': -1,
    'random_state': 42
}
dtrain = lgb.Dataset(X_train, y_train)
gbm = lgb.train(lgb_params, dtrain, num_boost_round=100)
lgbm_probs = gbm.predict(X_test)

# Train MLP
mlp = MLPClassifier(
    hidden_layer_sizes=(128, 64, 32),
    activation="relu",
    solver="adam",
    alpha=1e-4,
    batch_size=512,
    learning_rate_init=1e-3,
    max_iter=30,
    random_state=42,
    verbose=False
)
mlp.fit(X_train, y_train)
mlp_probs = mlp.predict_proba(X_test)

def evaluate(signals, targets, lots=None):
    trades = 0
    wins = 0
    gross_win = 0.0
    gross_loss = 0.0
    pnl_hist = [0.0]
    
    for i in range(len(signals)):
        sig = signals[i]
        tgt = targets[i]
        lot = lots[i] if lots is not None else 1.0
        if sig == 0: continue
        trades += 1
        pnl = 0.0
        if sig == 1:
            if tgt == 0: wins += 1; pnl = 6.0 * lot; gross_win += pnl
            elif tgt == 2: pnl = -3.0 * lot; gross_loss += abs(pnl)
            else: pnl = -1.0 * lot; gross_loss += abs(pnl)
        elif sig == -1:
            if tgt == 2: wins += 1; pnl = 6.0 * lot; gross_win += pnl
            elif tgt == 0: pnl = -3.0 * lot; gross_loss += abs(pnl)
            else: pnl = -1.0 * lot; gross_loss += abs(pnl)
        pnl_hist.append(pnl_hist[-1] + pnl)
        
    win_rate = (wins / trades * 100.0) if trades > 0 else 0.0
    pf = (gross_win / gross_loss) if gross_loss > 0 else 99.9
    net = gross_win - gross_loss
    cum = np.array(pnl_hist)
    max_dd = np.max(np.maximum.accumulate(cum) - cum) if len(cum) > 0 else 0.0
    return trades, win_rate, pf, net, max_dd

print("=" * 95)
print(f"{'Config Description':<45} | {'Trades':<7} | {'Win %':<7} | {'PF':<7} | {'Net Return':<12} | {'Max DD':<8}")
print("=" * 95)

# Test combinations
configs = [
    ("Baseline (Rigid LGBM>=0.58 & MLP>=0.58)", 0.58, 0.58, 0.58, "rigid"),
    ("Solo Conservative: LGBM>=0.58 | MLP>=0.72 | Syn>=0.54", 0.58, 0.72, 0.54, "smart"),
    ("Solo Balanced:     LGBM>=0.56 | MLP>=0.68 | Syn>=0.52", 0.56, 0.68, 0.52, "smart"),
    ("Solo Dynamic:      LGBM>=0.54 | MLP>=0.65 | Syn>=0.50", 0.54, 0.65, 0.50, "smart"),
]

for desc, l_th, m_th, syn_th, mode in configs:
    signals = np.zeros(len(X_test), dtype=int)
    lots = np.ones(len(X_test), dtype=float)
    
    for i in range(len(X_test)):
        l_b, l_n, l_r = lgbm_probs[i]
        m_b, m_n, m_r = mlp_probs[i]
        
        if mode == "rigid":
            if l_b >= l_th and m_b >= m_th: signals[i] = 1
            elif l_r >= l_th and m_r >= m_th: signals[i] = -1
        else: # smart
            # Synergy
            if l_b >= syn_th and m_b >= syn_th:
                signals[i] = 1; lots[i] = 1.25
            elif l_r >= syn_th and m_r >= syn_th:
                signals[i] = -1; lots[i] = 1.25
            # Solo LGBM
            elif l_b >= l_th and m_r < 0.60:
                signals[i] = 1; lots[i] = 1.0
            elif l_r >= l_th and m_b < 0.60:
                signals[i] = -1; lots[i] = 1.0
            # Solo MLP
            elif m_b >= m_th and l_r < 0.60:
                signals[i] = 1; lots[i] = 1.0
            elif m_r >= m_th and l_b < 0.60:
                signals[i] = -1; lots[i] = 1.0
                
    tr, wr, pf, net, dd = evaluate(signals, y_test, lots)
    print(f"{desc:<45} | {tr:<7,d} | {wr:>5.2f}% | {pf:>5.2f} | {net:>10.1f} $ | {dd:>6.1f} $")

print("=" * 95)
