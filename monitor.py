#!/usr/bin/env python3
import time, json, os
from datetime import datetime
STATUS_FILE = "/root/HFT_Bot/hft_status.json"
def show(s):
    os.system("clear")
    pnl = s.get('day_pnl', 0)
    t = s.get('trades',0); w = s.get('wins',0)
    print("="*48)
    print("  XAUUSD HFT v6.5 LIVE MONITOR")
    print("="*48)
    print(f"  Time:     {s.get('time','—')}")
    print(f"  Balance:  ${s.get('balance',0):>12,.2f}")
    print(f"  Equity:   ${s.get('equity',0):>12,.2f}")
    print(f"  Day P&L:  ${pnl:>+12,.2f}")
    print(f"  DD:       {s.get('drawdown_pct',0):.2f}%")
    print("-"*48)
    print(f"  Signal:   {s.get('signal','—')}")
    print(f"  EMA:      {s.get('ema_fast',0):.4f} / {s.get('ema_slow',0):.4f}")
    print(f"  Spread:   {s.get('spread_pts',0):.1f} pts")
    print(f"  Lot:      {s.get('lot_current',0):.2f} (step {s.get('scaling_steps',0):.0f})")
    print(f"  Status:   {s.get('status','—')}")
    print("-"*48)
    print(f"  Trades:   {t}  W:{w}  L:{s.get('losses',0)}")
    print(f"  WR:       {w/t*100:.1f}%" if t>0 else "  WR:       —")
    print("="*48)
while True:
    try:
        if os.path.exists(STATUS_FILE):
            with open(STATUS_FILE) as f: show(json.load(f))
        else:
            print(f"Waiting for {STATUS_FILE}...")
        time.sleep(5)
    except KeyboardInterrupt:
        print("\nStopped"); break
    except Exception as e:
        print(f"Error: {e}"); time.sleep(5)
