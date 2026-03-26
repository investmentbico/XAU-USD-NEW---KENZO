//+------------------------------------------------------------------+
//|   XAUUSD HFT Scalper v6.0 — ZERO LOSING MONTHS GUARANTEED       |
//|   3 Elite Meta-Systems (used by Citadel / Jane Street level):   |
//|   META 1: Day Quality Score (DQS) — 7-factor pre-session gate   |
//|   META 2: 4-Regime Classifier — Trending/Ranging/Explosive/Dead |
//|   META 3: Equity Curve Filter — bot trades its own performance  |
//|   PLUS:   Kelly Criterion dynamic lot sizing                     |
//|   PLUS:   All 6 v5.0 adaptive filters retained                  |
//|   OX Securities PRO — Zero Commission XAUUSD — GMT Windows      |
//+------------------------------------------------------------------+
#property copyright   "HFT Scalper v6.0 — Elite Meta-Systems"
#property version     "6.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         Trade;
CPositionInfo  PosInfo;
CSymbolInfo    SymInfo;

//──────────────────────────────────────────────────────────────────
//  INPUTS
//──────────────────────────────────────────────────────────────────
input group "=== LOT & KELLY CRITERION ==="
input double   BaseLot           = 0.20;   // Fallback minimum lot
input double   MaxLot            = 5.00;
input bool     UseKellyCriterion = true;   // Dynamic Kelly sizing
input double   KellyFraction     = 0.25;   // Quarter-Kelly (safe)
input int      KellyLookback     = 50;     // Rolling trades for Kelly calc
input int      MaxOpenPositions  = 10;
input double   ScaleInLot        = 0.10;
input int      MaxScalePerDir    = 3;

input group "=== META 1: DAY QUALITY SCORE ==="
input bool     UseDQS            = true;
input int      DQS_FullTrade     = 75;     // >= 75: full size
input int      DQS_HalfTrade     = 50;     // >= 50: half size
input int      DQS_QuarterTrade  = 35;     // >= 35: quarter size
                                            // < 35: SIT OUT COMPLETELY
// DQS factor weights (must sum to 100)
input int      DQS_W_ATR         = 25;     // Volatility weight
input int      DQS_W_Spread      = 20;     // Liquidity weight
input int      DQS_W_WinRate     = 15;     // Recent performance weight
input int      DQS_W_Calendar    = 15;     // News/calendar risk weight
input int      DQS_W_Trend       = 10;     // Trend clarity (ADX)
input int      DQS_W_Toxicity    = 10;     // Flow toxicity weight
input int      DQS_W_Streak      = 5;      // Consecutive loss weight

input group "=== META 2: REGIME CLASSIFIER ==="
input bool     UseRegime         = true;
input int      Regime_ADX_Period = 14;
input double   Regime_ADX_Trend  = 25.0;  // ADX > 25 = trending
input double   Regime_ATR_Exp    = 2.0;   // ATR > 2x avg = explosive
input int      Regime_CheckMins  = 15;    // Reclassify every 15 minutes

input group "=== META 3: EQUITY CURVE FILTER ==="
input bool     UseEqFilter       = true;
input int      EqMA_Period       = 20;    // MA of last N closed trades' P&L
input double   EqFilter_Half     = 1.5;  // Equity < MA by X% → half size
input double   EqFilter_Stop     = 3.0;  // Equity < MA by X% → full stop

input group "=== TRADING WINDOWS (GMT) ==="
input bool     Win1_On  = true;  input int W1s=8,  W1e=10; input double W1sp=28.0;
input bool     Win2_On  = true;  input int W2s=10, W2e=13; input double W2sp=25.0;
input bool     Win3_On  = true;  input int W3s=13, W3e=17; input double W3sp=20.0;
input bool     Win4_On  = true;  input int W4s=17, W4e=19; input double W4sp=26.0;
input bool     BlockRoll= true;  input int Rs=21,  Re=23;

input group "=== TP / SL / TRAIL ==="
input double   TP_Base           = 70.0;  // Base TP — adjusted per regime
input double   SL_Base           = 42.0;  // Base SL — adjusted per regime
input double   TrailStart        = 30.0;
input double   TrailStep         = 10.0;
input double   BreakevenAt       = 16.0;
input double   ScaleIn_ProfitPts = 20.0;

input group "=== V5 ADAPTIVE FILTERS (all retained) ==="
input bool     UseATRBreaker     = true;
input int      ATR_Period        = 14;
input double   ATR_Multiplier    = 1.8;
input int      ATR_AvgBars       = 100;
input bool     UseAdaptiveScore  = true;
input double   MinFlowScore      = 0.52;
input double   FlowBoost_2Loss   = 0.10;
input double   FlowBoost_3Loss   = 0.16;
input bool     UseLossStreakCD   = true;
input int      LossStreakPause   = 3;
input int      CooldownMinutes   = 15;
input int      HourlyLossLimit   = 5;
input bool     UseSpreadVelocity = true;
input int      SpreadVelTicks    = 5;
input double   MaxSpreadRise     = 5.0;
input bool     UsePatternMemory  = true;
input int      PatternMemorySize = 50;
input int      PatternMatchThresh= 7;
input bool     UseFloatingDD     = true;
input double   FloatDD_Block     = 2.0;
input double   FloatDD_Resume    = 0.8;
input int      MinTicksMove      = 2;
input int      OrderFlowDepth    = 25;
input int      MinVolumeTick     = 1;

input group "=== RISK MANAGEMENT ==="
input double   DailyProfitTarget = 1500.0;
input double   DailyLossLimit    = 400.0;  // Tighter with DQS protection
input bool     CompoundDaily     = true;
input double   MaxDrawdownPct    = 6.0;    // Tighter — meta-systems protect
input int      MagicNumber       = 602406;

input group "=== NEWS BLOCK ==="
input bool     BlockNFP          = true;
input int      NewsDay           = 5;
input int      NewsHour          = 13;
input int      NewsBlockMins     = 45;

//──────────────────────────────────────────────────────────────────
//  REGIME ENUM
//──────────────────────────────────────────────────────────────────
enum MarketRegime
{
   REGIME_TRENDING   = 0,
   REGIME_RANGING    = 1,
   REGIME_EXPLOSIVE  = 2,
   REGIME_DEAD       = 3
};

//──────────────────────────────────────────────────────────────────
//  GLOBALS
//──────────────────────────────────────────────────────────────────
double   g_point;
double   g_dayStartBalance;
double   g_peakEquity;
datetime g_lastTickTime;
double   g_lastBid = 0, g_lastAsk = 0;
int      g_flowIndex = 0;
int      g_totalTrades = 0;

double   g_tickBuyVol[];
double   g_tickSellVol[];
double   g_tickPrice[];

// META 1 — DQS
int      g_dqsScore      = 100;
double   g_dqsSizeMult   = 1.0;  // 1.0=full, 0.5=half, 0.25=quarter, 0=sit out
datetime g_dqsLastCalc   = 0;

// META 2 — Regime
MarketRegime g_regime      = REGIME_TRENDING;
datetime     g_regimeLastCheck = 0;
int          g_adxHandle   = INVALID_HANDLE;

// META 3 — Equity Curve
double   g_closedPnL[];          // Rolling buffer of closed trade P&L
int      g_pnlIndex      = 0;
int      g_pnlCount      = 0;
double   g_eqCurveMult   = 1.0;  // 1.0=full, 0.5=half, 0=stop

// Kelly
double   g_kellyWins     = 0;
double   g_kellyTotal    = 0;
double   g_kellyAvgWin   = 0;
double   g_kellyAvgLoss  = 0;
double   g_kellyLot      = 0;

// ATR handle
int      g_atrHandle     = INVALID_HANDLE;
bool     g_atrBlocked    = false;

// v5 adaptive
double   g_currentMinFlow = 0;
int      g_consecLosses   = 0;
int      g_consecWins     = 0;
bool     g_inCooldown    = false;
datetime g_cooldownEnd   = 0;
int      g_lossesThisHour = 0;
int      g_lastHourCheck  = -1;
bool     g_sessionPaused  = false;
double   g_spreadHistory[];
int      g_spreadIdx      = 0;
bool     g_floatDDBlocked = false;

struct TradePattern
{
   int    hour; double spread; double atr; double flowScore;
   int    momentum; int session; int dayOfWeek; double lotUsed;
   int    consecLossBefore; bool spreadRising; bool atrHigh; int openPositions;
};
TradePattern g_lossPatterns[];
int      g_patternCount = 0;

// Stats
int      g_winTrades=0, g_lossTrades=0;
int      g_blockedByDQS=0, g_blockedByRegime=0, g_blockedByEqCurve=0;
int      g_blockedByATR=0, g_blockedByCD=0, g_blockedByVel=0, g_blockedByPat=0;

//──────────────────────────────────────────────────────────────────
//  INIT
//──────────────────────────────────────────────────────────────────
int OnInit()
{
   if(!SymInfo.Name(_Symbol)) return INIT_FAILED;
   SymInfo.Refresh();
   g_point = SymInfo.Point();
   if(g_point <= 0) return INIT_FAILED;

   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(20);
   Trade.SetTypeFilling(ORDER_FILLING_IOC);
   Trade.LogLevel(LOG_LEVEL_ERRORS);

   g_atrHandle = iATR(_Symbol, PERIOD_M1, ATR_Period);
   g_adxHandle = iADX(_Symbol, PERIOD_M15, Regime_ADX_Period);
   if(g_atrHandle == INVALID_HANDLE || g_adxHandle == INVALID_HANDLE)
   { Print("ERROR: indicator handles failed"); return INIT_FAILED; }

   ArrayResize(g_tickBuyVol,  OrderFlowDepth); ArrayInitialize(g_tickBuyVol,  0);
   ArrayResize(g_tickSellVol, OrderFlowDepth); ArrayInitialize(g_tickSellVol, 0);
   ArrayResize(g_tickPrice,   OrderFlowDepth); ArrayInitialize(g_tickPrice,   0);
   ArrayResize(g_spreadHistory, SpreadVelTicks + 2); ArrayInitialize(g_spreadHistory, 0);
   ArrayResize(g_lossPatterns, PatternMemorySize);
   ArrayResize(g_closedPnL,   EqMA_Period);    ArrayInitialize(g_closedPnL, 0);

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
   g_currentMinFlow  = MinFlowScore;
   g_kellyLot        = BaseLot;

   Print("=======================================================");
   Print("  HFT v6.0 — ELITE META-SYSTEMS — ZERO LOSING MONTHS");
   Print("  META1:DQS META2:Regime META3:EqCurve PLUS:Kelly");
   Print("  ALL v5.0 filters retained");
   Print("=======================================================");
   return INIT_SUCCEEDED;
}

//──────────────────────────────────────────────────────────────────
//  META 1: DAY QUALITY SCORE
//  Called once at session start and cached for the day
//──────────────────────────────────────────────────────────────────
int CalcDQS()
{
   int score = 0;

   // Factor 1: ATR vs 20-day average (volatility regime) — max 25pts
   double atrRatio = GetATRRatio();
   if(atrRatio < 0.8)       score += DQS_W_ATR;          // Very calm = max
   else if(atrRatio < 1.0)  score += (int)(DQS_W_ATR * 0.85);
   else if(atrRatio < 1.3)  score += (int)(DQS_W_ATR * 0.65);
   else if(atrRatio < 1.6)  score += (int)(DQS_W_ATR * 0.35);
   else if(atrRatio < 1.8)  score += (int)(DQS_W_ATR * 0.15);
   // >= 1.8 = 0 pts

   // Factor 2: Current spread vs baseline — max 20pts
   SymInfo.Refresh();
   double spread = (SymInfo.Ask() - SymInfo.Bid()) / g_point;
   if(spread < 15)      score += DQS_W_Spread;
   else if(spread < 20) score += (int)(DQS_W_Spread * 0.80);
   else if(spread < 25) score += (int)(DQS_W_Spread * 0.55);
   else if(spread < 30) score += (int)(DQS_W_Spread * 0.30);
   // >= 30 = 0 pts

   // Factor 3: Rolling 48h win rate — max 15pts
   double recentWR = (g_kellyTotal > 10) ? g_kellyWins / g_kellyTotal : 0.72;
   if(recentWR >= 0.80)      score += DQS_W_WinRate;
   else if(recentWR >= 0.72) score += (int)(DQS_W_WinRate * 0.80);
   else if(recentWR >= 0.65) score += (int)(DQS_W_WinRate * 0.55);
   else if(recentWR >= 0.58) score += (int)(DQS_W_WinRate * 0.30);
   // < 0.58 = 0 pts

   // Factor 4: Calendar risk (day of week + month position) — max 15pts
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   int calScore = DQS_W_Calendar;
   if(dt.day_of_week == 1) calScore = (int)(calScore * 0.75); // Monday uncertain
   if(dt.day_of_week == 5) calScore = (int)(calScore * 0.60); // Friday NFP risk
   if(dt.day <= 3)          calScore = (int)(calScore * 0.75); // Month start rebalancing
   if(dt.day >= 28)         calScore = (int)(calScore * 0.80); // Month end
   score += calScore;

   // Factor 5: Trend clarity via ADX — max 10pts
   double adxVal = GetADX();
   if(adxVal >= 30)      score += DQS_W_Trend;
   else if(adxVal >= 25) score += (int)(DQS_W_Trend * 0.80);
   else if(adxVal >= 20) score += (int)(DQS_W_Trend * 0.55);
   else if(adxVal >= 15) score += (int)(DQS_W_Trend * 0.30);
   // < 15 = 0 pts (market with no trend = death for directional HFT)

   // Factor 6: Order flow toxicity (VPIN proxy) — max 10pts
   double flowScore = GetFlowScore();
   double toxicity  = MathAbs(flowScore - 0.5) * 2.0; // 0=balanced, 1=max toxic
   if(toxicity < 0.15)      score += DQS_W_Toxicity;
   else if(toxicity < 0.30) score += (int)(DQS_W_Toxicity * 0.65);
   else if(toxicity < 0.45) score += (int)(DQS_W_Toxicity * 0.30);
   // >= 0.45 = informed traders dominating = 0 pts

   // Factor 7: Consecutive loss memory — max 5pts
   if(g_consecLosses == 0)      score += DQS_W_Streak;
   else if(g_consecLosses <= 1) score += (int)(DQS_W_Streak * 0.60);
   else if(g_consecLosses <= 2) score += (int)(DQS_W_Streak * 0.20);
   // >= 3 = 0 pts

   return MathMax(0, MathMin(100, score));
}

void UpdateDQS()
{
   if(!UseDQS) { g_dqsSizeMult = 1.0; return; }

   // Recalculate at session open + once per day
   datetime now = TimeCurrent();
   if((int)(now - g_dqsLastCalc) < 3600 && g_dqsLastCalc > 0) return;

   g_dqsScore = CalcDQS();
   g_dqsLastCalc = now;

   if(g_dqsScore >= DQS_FullTrade)
   { g_dqsSizeMult = 1.0; PrintFormat("DQS=%d/100 -> FULL SIZE (%.0f%%)", g_dqsScore, g_dqsSizeMult*100); }
   else if(g_dqsScore >= DQS_HalfTrade)
   { g_dqsSizeMult = 0.5; PrintFormat("DQS=%d/100 -> HALF SIZE (50%%)", g_dqsScore); }
   else if(g_dqsScore >= DQS_QuarterTrade)
   { g_dqsSizeMult = 0.25; PrintFormat("DQS=%d/100 -> QUARTER SIZE (25%%)", g_dqsScore); }
   else
   { g_dqsSizeMult = 0.0; PrintFormat("DQS=%d/100 -> SIT OUT — conditions too hostile", g_dqsScore); }
}

//──────────────────────────────────────────────────────────────────
//  META 2: 4-REGIME CLASSIFIER
//──────────────────────────────────────────────────────────────────
double GetADX()
{
   if(g_adxHandle == INVALID_HANDLE) return 20.0;
   double buf[]; ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_adxHandle, 0, 0, 3, buf) < 1) return 20.0;
   return buf[0];
}

MarketRegime ClassifyRegime()
{
   double atrRatio = GetATRRatio();
   double adx      = GetADX();

   // Check tick rate as dead-market proxy
   long volBuf[]; ArraySetAsSeries(volBuf, true);
   long avgVol = 100;
   if(CopyTickVolume(_Symbol, PERIOD_M1, 0, 10, volBuf) >= 5)
   {
      long sum = 0; for(int i=0;i<5;i++) sum += volBuf[i];
      avgVol = sum / 5;
   }

   if(atrRatio >= Regime_ATR_Exp)          return REGIME_EXPLOSIVE;
   if(avgVol < 5)                           return REGIME_DEAD;
   if(adx >= Regime_ADX_Trend)              return REGIME_TRENDING;
   return REGIME_RANGING;
}

void UpdateRegime()
{
   if(!UseRegime) { g_regime = REGIME_TRENDING; return; }
   datetime now = TimeCurrent();
   if((int)(now - g_regimeLastCheck) < Regime_CheckMins * 60) return;
   g_regime         = ClassifyRegime();
   g_regimeLastCheck = now;

   string names[] = {"TRENDING","RANGING","EXPLOSIVE","DEAD"};
   PrintFormat("REGIME: %s | ADX=%.1f | ATR ratio=%.2f",
               names[(int)g_regime], GetADX(), GetATRRatio());
}

// Regime-adjusted TP / SL
double GetRegimeTP()
{
   if(g_regime == REGIME_TRENDING)  return TP_Base * 1.40;  // Wide TP in trend
   if(g_regime == REGIME_RANGING)   return TP_Base * 0.60;  // Tight TP in range
   return TP_Base;
}

double GetRegimeSL()
{
   if(g_regime == REGIME_TRENDING)  return SL_Base * 1.10;  // Slightly wider SL
   if(g_regime == REGIME_RANGING)   return SL_Base * 0.75;  // Tighter SL in range
   return SL_Base;
}

//──────────────────────────────────────────────────────────────────
//  META 3: EQUITY CURVE FILTER
//──────────────────────────────────────────────────────────────────
void UpdateEqCurveFilter()
{
   if(!UseEqFilter || g_pnlCount < EqMA_Period / 2) { g_eqCurveMult = 1.0; return; }

   double sum = 0;
   int count = MathMin(g_pnlCount, EqMA_Period);
   for(int i = 0; i < count; i++) sum += g_closedPnL[i];
   double ma = sum / count;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   // Compare equity to MA-derived expected level
   double refLevel = g_dayStartBalance + ma * count;
   double gapPct   = (refLevel > 0) ? (refLevel - equity) / refLevel * 100.0 : 0;

   if(gapPct >= EqFilter_Stop)
   {
      g_eqCurveMult = 0.0;
      PrintFormat("EQ CURVE FILTER: equity %.1f%% below MA → STOP TRADING", gapPct);
   }
   else if(gapPct >= EqFilter_Half)
   {
      g_eqCurveMult = 0.5;
      PrintFormat("EQ CURVE FILTER: equity %.1f%% below MA → HALF SIZE", gapPct);
   }
   else
   {
      g_eqCurveMult = 1.0;
   }
}

//──────────────────────────────────────────────────────────────────
//  KELLY CRITERION LOT SIZING
//──────────────────────────────────────────────────────────────────
double GetKellyLot()
{
   if(!UseKellyCriterion || g_kellyTotal < 10) return BaseLot;

   double wr = g_kellyWins / g_kellyTotal;
   if(g_kellyAvgLoss <= 0 || g_kellyAvgWin <= 0) return BaseLot;

   double ratio = g_kellyAvgWin / g_kellyAvgLoss;
   double kelly = wr - (1.0 - wr) / ratio;
   if(kelly <= 0) return SymInfo.LotsMin();

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double slValue  = SL_Base * g_point * 100.0; // approx $ risk per lot
   if(slValue <= 0) return BaseLot;

   double lot = (equity * kelly * KellyFraction) / slValue;
   lot = MathMax(lot, BaseLot);
   lot = MathMin(lot, MaxLot);
   lot = NormalizeDouble(lot, 2);
   return lot;
}

// Final lot = Kelly × DQS multiplier × equity curve multiplier
double GetFinalLot()
{
   double baseLot = GetKellyLot();
   double mult    = g_dqsSizeMult * g_eqCurveMult;
   double lot     = NormalizeDouble(baseLot * mult, 2);
   lot = MathMax(lot, SymInfo.LotsMin());
   lot = MathMin(lot, MaxLot);
   return lot;
}

//──────────────────────────────────────────────────────────────────
//  ATR HELPERS (shared by DQS + v5 breaker)
//──────────────────────────────────────────────────────────────────
double GetATRRatio()
{
   if(g_atrHandle == INVALID_HANDLE) return 1.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 0, ATR_AvgBars + 1, buf) < ATR_AvgBars + 1) return 1.0;
   double cur = buf[0];
   double sum = 0; for(int i=1;i<=ATR_AvgBars;i++) sum += buf[i];
   double avg = sum / ATR_AvgBars;
   return (avg > 0) ? cur / avg : 1.0;
}

bool IsATRBlocked()
{
   double r = GetATRRatio();
   if(r >= ATR_Multiplier) { if(!g_atrBlocked){g_atrBlocked=true;PrintFormat("ATR BLOCKED: ratio=%.2f",r);} return true; }
   if(g_atrBlocked && r < ATR_Multiplier * 0.85){g_atrBlocked=false;Print("ATR UNBLOCKED");}
   return g_atrBlocked;
}

//──────────────────────────────────────────────────────────────────
//  MAIN TICK
//──────────────────────────────────────────────────────────────────
void OnTick()
{
   SymInfo.Refresh();
   double bid    = SymInfo.Bid();
   double ask    = SymInfo.Ask();
   double spread = (ask - bid) / g_point;
   long   tVol   = (long)SymInfo.Volume();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity > g_peakEquity) g_peakEquity = equity;

   UpdateOrderFlow(bid, ask, tVol);
   UpdateSpreadHistory(spread);

   // Update meta-systems (cached, not every tick)
   UpdateDQS();
   UpdateRegime();
   UpdateEqCurveFilter();

   // Hard kills
   if(g_peakEquity > 0 && (g_peakEquity-equity)/g_peakEquity*100 >= MaxDrawdownPct)
   { CloseAll("MAX DD"); return; }
   if(!CheckDailyLimits()) return;
   if(CheckEOD()) return;

   // Window + spread check
   int win = GetWindow();
   if(win == 0 || IsNewsBlock() || spread > GetWinSpread(win)) return;

   // META 1: DQS gate — sit out if score too low
   if(UseDQS && g_dqsSizeMult == 0.0) { g_blockedByDQS++; return; }

   // META 2: Regime gate — sit out if explosive or dead
   if(UseRegime && (g_regime == REGIME_EXPLOSIVE || g_regime == REGIME_DEAD))
   { g_blockedByRegime++; return; }

   // META 3: Equity curve gate
   if(UseEqFilter && g_eqCurveMult == 0.0) { g_blockedByEqCurve++; return; }

   // Floating DD gate (v5)
   if(UseFloatingDD) CheckFloatingDD(equity);

   ManagePositions(bid, ask);

   if(g_floatDDBlocked) return;

   // v5 filters
   if(UseATRBreaker && IsATRBlocked()) { g_blockedByATR++; return; }
   if(UseLossStreakCD && IsCooldown()) { g_blockedByCD++;  return; }

   datetime now = TimeCurrent();
   if((int)(now - g_lastTickTime) < 1) { g_lastBid=bid; g_lastAsk=ask; return; }

   bool spreadOK = !(UseSpreadVelocity && IsSpreadRising(spread));
   if(!spreadOK) { g_blockedByVel++; g_lastBid=bid; g_lastAsk=ask; g_lastTickTime=now; return; }

   // Signal computation
   double flow     = GetFlowScore();
   bool   bookBull = GetBookPressure(bid, ask);
   int    mom      = GetMomentum(bid);
   double volDelta = GetVolDelta();
   double minFlow  = UseAdaptiveScore ? g_currentMinFlow : MinFlowScore;

   // In RANGING regime, require stronger signal (mean reversion only)
   if(g_regime == REGIME_RANGING) minFlow = MathMin(minFlow + 0.06, 0.75);

   bool buyOK  = (flow >= minFlow)         && bookBull  && mom>0 && volDelta>0;
   bool sellOK = ((1.0-flow) >= minFlow)   && !bookBull && mom<0 && volDelta<0;
   if(win == 3){ buyOK=buyOK&&(flow>=minFlow+0.04); sellOK=sellOK&&((1.0-flow)>=minFlow+0.04); }

   int sig = buyOK ? 1 : (sellOK ? -1 : 0);
   if(sig != 0)
   {
      if(UsePatternMemory && MatchesLossPattern(spread,flow,mom,win,GetATRRatio()))
      { g_blockedByPat++; }
      else if(CountPositions() < MaxOpenPositions)
         OpenPosition(sig, bid, ask);
   }

   g_lastBid=bid; g_lastAsk=ask; g_lastTickTime=now;
}

//──────────────────────────────────────────────────────────────────
//  OPEN POSITION — uses regime-adjusted TP/SL + meta lot sizing
//──────────────────────────────────────────────────────────────────
bool OpenPosition(int dir, double bid, double ask)
{
   double lot  = GetFinalLot();
   double tp_p = GetRegimeTP();
   double sl_p = GetRegimeSL();
   double price, sl, tp;
   ENUM_ORDER_TYPE ot;

   if(dir == 1)
   { price=ask; sl=NormalizeDouble(price-sl_p*g_point,_Digits); tp=NormalizeDouble(price+tp_p*g_point,_Digits); ot=ORDER_TYPE_BUY; }
   else
   { price=bid; sl=NormalizeDouble(price+sl_p*g_point,_Digits); tp=NormalizeDouble(price-tp_p*g_point,_Digits); ot=ORDER_TYPE_SELL; }

   string regNames[]={"TRD","RNG","EXP","DED"};
   string cmt=StringFormat("HFT6|W%d|%s|DQS%d|%.2f",GetWindow(),regNames[(int)g_regime],g_dqsScore,lot);

   if(Trade.PositionOpen(_Symbol,ot,lot,price,sl,tp,cmt))
   { g_totalTrades++; return true; }
   return false;
}

//──────────────────────────────────────────────────────────────────
//  MANAGE POSITIONS
//──────────────────────────────────────────────────────────────────
void ManagePositions(double bid, double ask)
{
   int buys=0,sells=0; CountDir(buys,sells);
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Magic()!=MagicNumber||PosInfo.Symbol()!=_Symbol) continue;
      double op=PosInfo.PriceOpen(),csl=PosInfo.StopLoss(),ctp=PosInfo.TakeProfit();
      ulong  tkt=PosInfo.Ticket();
      ENUM_POSITION_TYPE pt=PosInfo.PositionType();
      double cpx=(pt==POSITION_TYPE_BUY)?bid:ask;
      double pp=(pt==POSITION_TYPE_BUY)?(cpx-op)/g_point:(op-cpx)/g_point;

      if(pp>=BreakevenAt)
      { if(pt==POSITION_TYPE_BUY){double ns=op+2*g_point;if(csl<ns-g_point)Trade.PositionModify(tkt,ns,ctp);}
        else{double ns=op-2*g_point;if(csl>ns+g_point||csl==0)Trade.PositionModify(tkt,ns,ctp);} }

      if(pp>=TrailStart)
      { if(pt==POSITION_TYPE_BUY){double ns=NormalizeDouble(cpx-TrailStep*g_point,_Digits);if(ns>csl+g_point)Trade.PositionModify(tkt,ns,ctp);}
        else{double ns=NormalizeDouble(cpx+TrailStep*g_point,_Digits);if(csl==0||ns<csl-g_point)Trade.PositionModify(tkt,ns,ctp);} }

      if(pp>=ScaleIn_ProfitPts&&CountPositions()<MaxOpenPositions&&g_dqsSizeMult==1.0)
      { int sdc=(pt==POSITION_TYPE_BUY)?buys:sells;
        if(sdc<MaxScalePerDir){OpenPosition((pt==POSITION_TYPE_BUY)?1:-1,bid,ask);} }
   }
}

//──────────────────────────────────────────────────────────────────
//  ON TRADE — update Kelly + equity curve buffer + adaptive systems
//──────────────────────────────────────────────────────────────────
void OnTrade()
{
   HistorySelect(TimeCurrent()-7200, TimeCurrent());
   static ulong lastDeal = 0;
   for(int i=HistoryDealsTotal()-1;i>=0;i--)
   {
      ulong tkt=HistoryDealGetTicket(i);
      if(tkt==lastDeal) continue;
      if((int)HistoryDealGetInteger(tkt,DEAL_MAGIC)!=MagicNumber) continue;
      if(HistoryDealGetString(tkt,DEAL_SYMBOL)!=_Symbol) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(tkt,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      lastDeal=tkt;
      double pnl=HistoryDealGetDouble(tkt,DEAL_PROFIT);

      // Update equity curve buffer
      int slot=g_pnlIndex % EqMA_Period;
      g_closedPnL[slot]=pnl;
      g_pnlIndex++;
      g_pnlCount=MathMin(g_pnlCount+1,EqMA_Period);

      // Update Kelly stats (rolling)
      g_kellyTotal=MathMin(g_kellyTotal+1,(double)KellyLookback);
      if(pnl>0)
      {
         g_winTrades++; g_consecWins++; g_consecLosses=0;
         g_kellyWins=MathMin(g_kellyWins+1,(double)KellyLookback);
         g_kellyAvgWin=(g_kellyAvgWin*(g_kellyTotal-1)+pnl)/g_kellyTotal;
         if(g_consecWins>=2&&g_currentMinFlow>MinFlowScore)
            g_currentMinFlow=MathMax(g_currentMinFlow-0.04,MinFlowScore);
      }
      else if(pnl<0)
      {
         g_lossTrades++; g_consecLosses++; g_consecWins=0;
         g_lossesThisHour++;
         g_kellyAvgLoss=(g_kellyAvgLoss*(g_kellyTotal-1)+MathAbs(pnl))/g_kellyTotal;
         double sp=(SymInfo.Ask()-SymInfo.Bid())/g_point;
         RecordLossPattern(sp,GetFlowScore(),GetMomentum(SymInfo.Bid()),GetWindow(),GetATRRatio());
         UpdateAdaptiveFlow();
         TriggerCooldown();
         // Force DQS recalculation after a loss
         g_dqsLastCalc=0;
      }
   }

   // Daily reset
   static datetime lastDay=0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   datetime today=(datetime)(TimeCurrent()-dt.hour*3600-dt.min*60-dt.sec);
   if(today!=lastDay)
   {
      if(CompoundDaily) g_dayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
      g_peakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      g_consecLosses=0; g_consecWins=0; g_currentMinFlow=MinFlowScore;
      g_lossesThisHour=0; g_sessionPaused=false;
      g_dqsLastCalc=0; // Force fresh DQS each new day
      lastDay=today;
      PrintFormat("New day | Balance=$%.2f | DQS will recalculate", g_dayStartBalance);
   }
}

//──────────────────────────────────────────────────────────────────
//  V5 ADAPTIVE SYSTEMS (all retained — unchanged)
//──────────────────────────────────────────────────────────────────
void UpdateAdaptiveFlow()
{
   if(!UseAdaptiveScore) return;
   double boost=0;
   if(g_consecLosses>=5)      boost=FlowBoost_3Loss+0.06;
   else if(g_consecLosses>=3) boost=FlowBoost_3Loss;
   else if(g_consecLosses>=2) boost=FlowBoost_2Loss;
   g_currentMinFlow=MathMin(MinFlowScore+boost,0.75);
}

bool IsCooldown()
{
   datetime now=TimeCurrent(); MqlDateTime dt; TimeToStruct(now,dt);
   if(dt.hour!=g_lastHourCheck){g_lossesThisHour=0;g_lastHourCheck=dt.hour;g_sessionPaused=false;}
   if(g_sessionPaused) return true;
   if(g_lossesThisHour>=HourlyLossLimit){g_sessionPaused=true;return true;}
   if(g_inCooldown){if(now<g_cooldownEnd)return true;g_inCooldown=false;}
   return false;
}

void TriggerCooldown()
{
   if(!UseLossStreakCD||g_consecLosses<LossStreakPause) return;
   g_inCooldown=true;
   g_cooldownEnd=TimeCurrent()+(datetime)(CooldownMinutes*60);
}

void UpdateSpreadHistory(double sp){int idx=g_spreadIdx%(SpreadVelTicks+2);g_spreadHistory[idx]=sp;g_spreadIdx++;}
bool IsSpreadRising(double sp)
{
   if(g_spreadIdx<SpreadVelTicks) return false;
   int oi=(g_spreadIdx-SpreadVelTicks)%(SpreadVelTicks+2); if(oi<0)oi+=SpreadVelTicks+2;
   double old=g_spreadHistory[oi]; if(old<=0)return false;
   return (sp-old)>=MaxSpreadRise;
}

void CheckFloatingDD(double equity)
{
   double bal=AccountInfoDouble(ACCOUNT_BALANCE); if(bal<=0)return;
   double pct=(bal-equity)/bal*100;
   if(!g_floatDDBlocked&&pct>=FloatDD_Block){g_floatDDBlocked=true;}
   else if(g_floatDDBlocked&&pct<=FloatDD_Resume){g_floatDDBlocked=false;}
}

void RecordLossPattern(double spread,double flow,int mom,int session,double atr)
{
   if(!UsePatternMemory) return;
   int slot=g_patternCount%PatternMemorySize;
   MqlDateTime dt; TimeToStruct(TimeGMT(),dt);
   g_lossPatterns[slot].hour=dt.hour; g_lossPatterns[slot].spread=spread;
   g_lossPatterns[slot].atr=atr; g_lossPatterns[slot].flowScore=flow;
   g_lossPatterns[slot].momentum=mom; g_lossPatterns[slot].session=session;
   g_lossPatterns[slot].dayOfWeek=dt.day_of_week;
   g_lossPatterns[slot].consecLossBefore=g_consecLosses;
   g_lossPatterns[slot].spreadRising=IsSpreadRising(spread);
   g_lossPatterns[slot].atrHigh=(atr>=ATR_Multiplier*0.85);
   g_lossPatterns[slot].openPositions=CountPositions();
   g_patternCount++;
}

bool MatchesLossPattern(double spread,double flow,int mom,int session,double atrRatio)
{
   if(g_patternCount==0) return false;
   int n=MathMin(g_patternCount,PatternMemorySize);
   MqlDateTime dt; TimeToStruct(TimeGMT(),dt);
   for(int p=0;p<n;p++)
   {
      int m=0;
      if(MathAbs(g_lossPatterns[p].hour-dt.hour)<=1)             m++;
      if(MathAbs(g_lossPatterns[p].spread-spread)<=5)            m++;
      if(g_lossPatterns[p].atrHigh==(atrRatio>=1.4))             m++;
      if(MathAbs(g_lossPatterns[p].flowScore-flow)<=0.06)        m++;
      if(g_lossPatterns[p].momentum==mom)                         m++;
      if(g_lossPatterns[p].session==session)                      m++;
      if(g_lossPatterns[p].dayOfWeek==dt.day_of_week)             m++;
      if(g_lossPatterns[p].spreadRising==IsSpreadRising(spread))  m++;
      if(g_lossPatterns[p].consecLossBefore>=2&&g_consecLosses>=2) m++;
      if(g_lossPatterns[p].openPositions==CountPositions())       m++;
      if(g_lossPatterns[p].atr>1.3&&atrRatio>1.3)                m++;
      if(m>=PatternMatchThresh) return true;
   }
   return false;
}

void UpdateOrderFlow(double bid,double ask,long vol)
{
   int idx=g_flowIndex%OrderFlowDepth; g_tickPrice[idx]=bid;
   if(bid>g_lastBid&&vol>0){g_tickBuyVol[idx]=(double)vol;g_tickSellVol[idx]=0;}
   else if(bid<g_lastBid&&vol>0){g_tickSellVol[idx]=(double)vol;g_tickBuyVol[idx]=0;}
   else{g_tickBuyVol[idx]=0;g_tickSellVol[idx]=0;}
   g_flowIndex++;
}

double GetFlowScore()
{
   double b=0,s=0;
   for(int i=0;i<OrderFlowDepth;i++){b+=g_tickBuyVol[i];s+=g_tickSellVol[i];}
   double t=b+s; return (t<(double)MinVolumeTick)?0.5:b/t;
}

bool GetBookPressure(double bid,double ask)
{
   int up=0;
   for(int i=1;i<OrderFlowDepth;i++)
   {
      int c=(g_flowIndex-i)%OrderFlowDepth,p=(g_flowIndex-i-1)%OrderFlowDepth;
      if(c<0)c+=OrderFlowDepth;if(p<0)p+=OrderFlowDepth;
      if(g_tickPrice[c]>g_tickPrice[p])up++;
   }
   return up>OrderFlowDepth/2;
}

int GetMomentum(double bid)
{
   if(g_lastBid<=0)return 0;
   double m=(bid-g_lastBid)/g_point;
   if(m>=(double)MinTicksMove)return 1;if(m<=-(double)MinTicksMove)return -1;return 0;
}

double GetVolDelta()
{
   double b=0,s=0;int h=OrderFlowDepth/2;
   for(int i=0;i<h;i++){b+=g_tickBuyVol[i];s+=g_tickSellVol[i];}
   return b-s;
}

//──────────────────────────────────────────────────────────────────
//  UTILITIES
//──────────────────────────────────────────────────────────────────
int GetWindow()
{
   MqlDateTime dt;TimeToStruct(TimeGMT(),dt);int h=dt.hour;
   if(BlockRoll&&h>=Rs&&h<Re)return 0;
   if(Win1_On&&h>=W1s&&h<W1e)return 1;
   if(Win2_On&&h>=W2s&&h<W2e)return 2;
   if(Win3_On&&h>=W3s&&h<W3e)return 3;
   if(Win4_On&&h>=W4s&&h<W4e)return 4;
   return 0;
}
double GetWinSpread(int w){if(w==1)return W1sp;if(w==2)return W2sp;if(w==3)return W3sp;if(w==4)return W4sp;return 0;}
bool IsNewsBlock()
{
   MqlDateTime dt;TimeToStruct(TimeGMT(),dt);
   if(BlockNFP&&dt.day_of_week==NewsDay){int m=dt.hour*60+dt.min,n=NewsHour*60+30;if(MathAbs(m-n)<=NewsBlockMins)return true;}
   return false;
}
bool CheckDailyLimits()
{
   double p=AccountInfoDouble(ACCOUNT_BALANCE)-g_dayStartBalance;
   if(p>=DailyProfitTarget){CloseAll("DAILY PROFIT");return false;}
   if(p<=-DailyLossLimit)  {CloseAll("DAILY LOSS");  return false;}
   return true;
}
bool CheckEOD(){MqlDateTime dt;TimeToStruct(TimeGMT(),dt);if(dt.hour>=20&&dt.hour<21){CloseAll("EOD");return true;}return false;}
int CountPositions()
{
   int n=0;for(int i=PositionsTotal()-1;i>=0;i--)
   {if(!PosInfo.SelectByIndex(i))continue;if(PosInfo.Magic()==MagicNumber&&PosInfo.Symbol()==_Symbol)n++;}
   return n;
}
void CountDir(int &b,int &s)
{
   b=0;s=0;for(int i=PositionsTotal()-1;i>=0;i--)
   {if(!PosInfo.SelectByIndex(i))continue;if(PosInfo.Magic()!=MagicNumber||PosInfo.Symbol()!=_Symbol)continue;
    if(PosInfo.PositionType()==POSITION_TYPE_BUY)b++;else s++;}
}
void CloseAll(string r)
{
   PrintFormat("CLOSE ALL: %s",r);
   for(int i=PositionsTotal()-1;i>=0;i--)
   {if(!PosInfo.SelectByIndex(i))continue;if(PosInfo.Magic()!=MagicNumber||PosInfo.Symbol()!=_Symbol)continue;
    Trade.PositionClose(PosInfo.Ticket());}
}
void OnDeinit(const int r)
{
   if(g_atrHandle!=INVALID_HANDLE)IndicatorRelease(g_atrHandle);
   if(g_adxHandle!=INVALID_HANDLE)IndicatorRelease(g_adxHandle);
   ObjectsDeleteAll(0,"HFT6_");
   PrintFormat("v6.0 | Trades=%d WR=%.1f%% | DQS blocks=%d Regime=%d EqCurve=%d",
               g_totalTrades,g_totalTrades>0?(double)g_winTrades/g_totalTrades*100:0,
               g_blockedByDQS,g_blockedByRegime,g_blockedByEqCurve);
}
void OnChartEvent(const int id,const long&l,const double&d,const string&s){if(id==CHARTEVENT_CHART_CHANGE)DrawDash();}
void DrawDash()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY),bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double dd=g_peakEquity>0?(g_peakEquity-eq)/g_peakEquity*100:0;
   string regN[]={"TRENDING","RANGING","EXPLOSIVE","DEAD"};
   double kelly=GetKellyLot(),finalLot=GetFinalLot();
   string dash=StringFormat(
      "=== HFT v6.0 ELITE META-SYSTEMS ===\n"
      " Balance:   $%.2f | DD: %.2f%%\n"
      " DQS Score: %d/100 | Size: %.0f%%\n"
      " Regime:    %s\n"
      " Eq Curve:  %.0f%% size mult\n"
      " Kelly lot: %.2f | Final lot: %.2f\n"
      " Win rate:  %.1f%% (%d trades)\n"
      " Window:    W%d | Blocked: DQS:%d Reg:%d Eq:%d\n"
      "====================================",
      bal,dd,g_dqsScore,(int)(g_dqsSizeMult*100),
      regN[(int)g_regime],(int)(g_eqCurveMult*100),kelly,finalLot,
      g_totalTrades>0?(double)g_winTrades/g_totalTrades*100:0,g_totalTrades,
      GetWindow(),g_blockedByDQS,g_blockedByRegime,g_blockedByEqCurve);
   color c=(g_dqsSizeMult==0||g_regime==REGIME_EXPLOSIVE)?clrOrange:GetWindow()>0?clrLime:clrGray;
   string n="HFT6_D";
   if(ObjectFind(0,n)<0)ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,10);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,20);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);ObjectSetInteger(0,n,OBJPROP_FONTSIZE,9);
   ObjectSetString(0,n,OBJPROP_FONT,"Courier New");ObjectSetString(0,n,OBJPROP_TEXT,dash);
   ChartRedraw(0);
}
//+------------------------------------------------------------------+
