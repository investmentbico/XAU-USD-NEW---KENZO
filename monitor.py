#!/usr/bin/env python3
"""
XAUUSD HFT Monitor — runs on Digital Ocean
Reads hft_status.json synced from Mac MT5
"""
import time, json, os
from datetime import datetime

STATUS_FILE = "/root/HFT_Bot/hft_status.json"

def show(s):
    os.system("clear")
    pnl = s.get('day_pnl', 0)
    pnl_color = "\033[92m" if pnl >= 0 else "\033[91m"
    sig = s.get('signal','FLAT')
    sig_color = "\033[92m" if sig=="BUY" else "\033[91m" if sig=="SELL" else "\033[93m"
    reset = "\033[0m"
    t = s.get('trades',0); w = s.get('wins',0)
    print(f"\033[33m{'='*48}\033[0m")
    print(f"\033[33m  XAUUSD HFT v6.5 — LIVE MONITOR\033[0m")
    print(f"\033[33m{'='*48}\033[0m")
    print(f"  Time:     {s.get('time','—')}")
    print(f"  Symbol:   {s.get('symbol','XAUUSD.PRO')}  TF:{s.get('timeframe','M1')}")
    print(f"  Balance:  \033[97m${s.get('balance',0):>12,.2f}{reset}")
    print(f"  Equity:   \033[97m${s.get('equity',0):>12,.2f}{reset}")
    print(f"  Day P&L:  {pnl_color}${pnl:>+12,.2f}{reset}")
    print(f"  Drawdown: {s.get('drawdown_pct',0):.2f}%")
    print(f"\033[90m{'─'*48}\033[0m")
    print(f"  Signal:   {sig_color}{sig}{reset}")
    print(f"  EMA {s.get('ema_fast',0):.4f} / {s.get('ema_slow',0):.4f}")
    print(f"  Spread:   {s.get('spread_pts',0):.1f} pts")
    print(f"  ATR:      {s.get('atr_ratio',0):.2f}x")
    print(f"\033[90m{'─'*48}\033[0m")
    print(f"  Lot:      {s.get('lot_current',0):.2f}  (step {s.get('scaling_steps',0):.0f} | +{s.get('equity_gain_pct',0):.1f}%)")
    print(f"  Positions:{s.get('positions',0)}")
    print(f"  Status:   \033[96m{s.get('status','—')}{reset}")
    print(f"\033[90m{'─'*48}\033[0m")
    print(f"  Trades:   {t}   W:{w}   L:{s.get('losses',0)}")
    print(f"  Win rate: {w/t*100:.1f}%" if t > 0 else "  Win rate: —")
    print(f"\033[33m{'='*48}\033[0m")
    print(f"  Updated: {datetime.now().strftime('%H:%M:%S')} | Ctrl+C to stop")

print("XAUUSD HFT Monitor starting...")
while True:
    try:
        if os.path.exists(STATUS_FILE):
            with open(STATUS_FILE) as f:
                show(json.load(f))
        else:
            print(f"Waiting for {STATUS_FILE}...")
        time.sleep(5)
    except KeyboardInterrupt:
        print("\nMonitor stopped"); break
    except Exception as e:
        print(f"Error: {e}"); time.sleep(5)
