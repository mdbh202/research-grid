//+------------------------------------------------------------------+
//|                                    grid_trading_research.mql5      |
//|                        Intraday Grid EA — XAUUSD MT5 Hedging       |
//|                        Gate 1: Architecture Skeleton                |
//+------------------------------------------------------------------+
#property copyright   "Grid Trading Research Project"
#property version     "1.00"
#property description "Intraday Directional Grid with Mode Switching + Hedge Lock"
#property description "Target: XAUUSD on MT5 Hedging Account"
#property description "Build: Gate 1 — Architecture Skeleton (no execution logic)"
#property strict

//+------------------------------------------------------------------+
//| ENUMERATIONS                                                       |
//+------------------------------------------------------------------+
enum ENUM_CLUSTER_STATE
{
   CLUSTER_IDLE,          // No cluster active in this slot
   CLUSTER_OPENING,       // First leg placed, awaiting fill confirmation
   CLUSTER_NORMAL,        // Active, legs open, no hedge
   CLUSTER_LOCKED,        // Hedge lock active
   CLUSTER_UNLOCKING,     // Hedge closed, cluster recovering
   CLUSTER_CLOSING,       // Session exit or TP cascade in progress
   CLUSTER_CLOSED         // All legs closed, awaiting reset to IDLE
};

enum ENUM_GRID_MODE
{
   MODE_RANGE,            // ADX < ADXRangeThreshold — range grid
   MODE_DIRECTIONAL,      // ADX > ADXTrendThreshold — trend-following grid
   MODE_NEUTRAL           // Between thresholds — no new clusters
};

enum ENUM_CLUSTER_DIRECTION
{
   DIR_NONE  = 0,         // Unassigned
   DIR_LONG  = 1,         // Long cluster
   DIR_SHORT = 2          // Short cluster
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS — GROUP 1: ACCOUNT & RISK                        |
//+------------------------------------------------------------------+
input group "═══ Account & Risk ═══"
input double   RiskPerCluster          = 0.03;    // Risk per cluster (fraction of equity)
input int      MaxConcurrentClusters   = 3;       // Max simultaneous open clusters
input double   KillSwitchPct           = 0.05;    // Kill switch threshold (fraction of balance)
input double   ProtectionDrawdownPct   = 0.25;    // Account protection lockout (fraction of StartEquity)
input bool     ResetProtectionMode     = false;   // Manual reset: set true and reload EA
input int      MagicBase               = 120000;  // Base magic number (unique per EA instance)

//+------------------------------------------------------------------+
//| INPUT PARAMETERS — GROUP 2: GRID STRUCTURE                        |
//+------------------------------------------------------------------+
input group "═══ Grid Structure ═══"
input double            GridStepMultiplier     = 0.25;       // Grid step = ATR × this value
input double            GridStepFloor          = 5.00;       // Min grid step (USD)
input double            GridStepCap            = 18.00;      // Max grid step (USD)
input int               MaxLegs                = 5;          // Max legs per cluster
input double            TPMultiplier           = 1.50;       // TP per leg = GridStep × this
input int               LegScalingStart        = 4;          // First leg with scaled lot
input double            LegScalingFactor       = 1.50;       // Lot multiplier for scaled legs
input int               ATRPeriod              = 14;         // ATR calculation period
input ENUM_TIMEFRAMES   ATRTimeframe           = PERIOD_D1;  // ATR timeframe
// NEW
input double            SuspendATRPctThreshold = 6.0;     // ATR as % of price above which trading is suspended

//+------------------------------------------------------------------+
//| INPUT PARAMETERS — GROUP 3: MODE SWITCHING                        |
//+------------------------------------------------------------------+
input group "═══ Mode Switching (Trend/Range Detection) ═══"
input int               ADXPeriod             = 14;         // ADX calculation period
input ENUM_TIMEFRAMES   ADXTimeframe          = PERIOD_H1;  // ADX timeframe
input double            ADXRangeThreshold     = 22.0;       // Below → Range Mode
input double            ADXTrendThreshold     = 25.0;       // Above → Directional Mode
input int               TrendEMAPeriod        = 20;         // EMA period for trend direction
input ENUM_TIMEFRAMES   TrendEMATimeframe     = PERIOD_M15; // EMA timeframe
input int               BBPeriod              = 20;         // Bollinger Band period (Range Mode)
input double            BBDeviation           = 2.0;        // Bollinger Band deviation
input ENUM_TIMEFRAMES   BBTimeframe           = PERIOD_M15; // Bollinger Band timeframe

//+------------------------------------------------------------------+
//| INPUT PARAMETERS — GROUP 4: HEDGE LOCK                            |
//+------------------------------------------------------------------+
input group "═══ Hedge Lock ═══"
input bool     HedgeLockEnabled              = true;  // Enable hedge lock mechanism
input double   HedgeLockTriggerMultiplier    = 2.0;   // Lock at this × GridStep adverse
input double   HedgeUnlockMultiplier         = 1.0;   // Unlock at this × GridStep favorable from lock
input double   HedgeForceCloseMultiplier     = 1.0;   // Force close at this × GridStep adverse beyond lock
input int      MaxLocksPerCluster            = 1;     // Max concurrent locks per cluster

//+------------------------------------------------------------------+
//| INPUT PARAMETERS — GROUP 5: SESSION & TIME MANAGEMENT             |
//+------------------------------------------------------------------+
input group "═══ Session & Time ═══"
input int      SessionStartHour        = 2;    // Session start hour (UTC)
input int      SessionStartMinute      = 0;    // Session start minute (UTC)
input int      NewClusterCutoffHour    = 17;   // No new clusters after this hour (UTC)
input int      NewClusterCutoffMinute  = 0;    // Cutoff minute (UTC)
input int      SessionCloseHour        = 21;   // Force close all at this hour (UTC)
input int      SessionCloseMinute      = 0;    // Session close minute (UTC)
input int      FridayCloseHour         = 18;   // Friday weekend safety hour (UTC)
input int      FridayCloseMinute       = 30;   // Friday weekend safety minute (UTC)
input int      BrokerGMTOffset         = 0;    // Broker server offset from UTC

//+------------------------------------------------------------------+
//| INPUT PARAMETERS — GROUP 6: NEWS FILTER                           |
//+------------------------------------------------------------------+
input group "═══ News Filter ═══"
input bool     NewsFilterEnabled       = true;      // Enable news filter
input int      NewsBufferMinutes       = 30;        // No clusters ± this many minutes of news
input string   NewsFilterCurrencies    = "USD,EUR";  // Currencies to monitor
input int      NewsMinImportance       = 3;          // Min importance (3=high only)

//+------------------------------------------------------------------+
//| INPUT PARAMETERS — GROUP 7: LOGGING & ALERTS                      |
//+------------------------------------------------------------------+
input group "═══ Logging & Alerts ═══"
input bool     EnableCSVLogging        = true;                // Write events to CSV
input bool     EnablePushNotifications = true;                // Push notifications on critical events
input bool     EnableEmailAlerts       = false;               // Email on critical events
input string   LogFilePath             = "GridEA_Journal";    // CSV log file prefix

//+------------------------------------------------------------------+
//| INTERNAL CONSTANTS (not user-configurable)                        |
//+------------------------------------------------------------------+
#define MAX_LOT_MULTIPLIER           2.0     // Hard cap: no leg > 2× base lot
#define MAX_PORTFOLIO_HEAT_PCT       0.09    // 3 clusters × 3% = 9%
#define KILL_SWITCH_COOLDOWN_SESSIONS 1      // Sessions to wait after kill switch
#define ORDERSEND_MAX_RETRIES        3       // Max retries for failed OrderSend
#define ORDERSEND_RETRY_DELAY_MS     500     // ms between retries
#define HEDGE_MAGIC_OFFSET           3000    // Added to magic for hedge legs
#define TIER_ID                      2       // Intraday tier = 2
#define MIN_BARS_FOR_INDICATOR       30      // Min bars before trusting indicator
#define NEWS_CHECK_INTERVAL_SEC      60      // Seconds between calendar checks
#define SPREAD_TO_STEP_MAX_RATIO     0.15    // Max spread/step ratio for new clusters
#define MONDAY_UNWIND_DELAY_MIN      30      // Minutes after Monday open before unwind
#define MARGIN_SAFETY_FACTOR         0.80    // Only use 80% of free margin
#define MAX_LEGS_ABSOLUTE            7       // Absolute max legs (array sizing)
#define MAX_CLUSTERS_ABSOLUTE        5       // Absolute max clusters (array sizing)

//+------------------------------------------------------------------+
//| DATA STRUCTURES                                                    |
//+------------------------------------------------------------------+
struct LegInfo
{
   ulong    ticket;        // Position ticket
   int      legNumber;     // 1 to MaxLegs
   double   entryPrice;    // Fill price
   double   lotSize;       // Actual lot size
   double   tpPrice;       // Take profit price
   bool     isOpen;        // Currently open
   bool     isHedge;       // Is this the hedge leg
   datetime openTime;      // Time opened
   datetime closeTime;     // Time closed
   double   closePL;       // Realized P&L when closed
   
   void Reset()
   {
      ticket     = 0;
      legNumber  = 0;
      entryPrice = 0;
      lotSize    = 0;
      tpPrice    = 0;
      isOpen     = false;
      isHedge    = false;
      openTime   = 0;
      closeTime  = 0;
      closePL    = 0;
   }
};

struct ClusterInfo
{
   ENUM_CLUSTER_STATE     state;
   ENUM_GRID_MODE         mode;           // Mode at cluster open (frozen)
   ENUM_CLUSTER_DIRECTION direction;
   int                    clusterSeq;     // Sequential ID (001–999)
   int                    magicBase;      // Magic number for this cluster's legs
   int                    hedgeMagic;     // Magic for hedge leg
   double                 gridStep;       // Step at cluster open (frozen)
   double                 baseLot;        // Base lot at cluster open (frozen)
   double                 tpDistance;     // TP per leg (frozen)
   int                    legsOpened;     // Legs opened so far
   int                    legsClosed;     // Legs resolved (TP or stop)
   int                    locksActive;    // Current active locks (0 or 1)
   double                 lastLegPrice;   // Entry price of most recent leg
   double                 lockPrice;      // Hedge lock entry price (0 if not locked)
   datetime               openTime;       // First leg open time
   datetime               lockTime;       // Hedge lock activation time
   double                 totalLotsLong;  // Sum of long lots
   double                 totalLotsShort; // Sum of short lots
   LegInfo                legs[MAX_LEGS_ABSOLUTE + 1]; // +1 for hedge leg (index 0 = hedge, 1–7 = grid legs)
   
   void Reset()
   {
      state          = CLUSTER_IDLE;
      mode           = MODE_NEUTRAL;
      direction      = DIR_NONE;
      clusterSeq     = 0;
      magicBase      = 0;
      hedgeMagic     = 0;
      gridStep       = 0;
      baseLot        = 0;
      tpDistance      = 0;
      legsOpened     = 0;
      legsClosed     = 0;
      locksActive    = 0;
      lastLegPrice   = 0;
      lockPrice      = 0;
      openTime       = 0;
      lockTime       = 0;
      totalLotsLong  = 0;
      totalLotsShort = 0;
      
      for(int i = 0; i <= MAX_LEGS_ABSOLUTE; i++)
         legs[i].Reset();
   }
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                   |
//+------------------------------------------------------------------+

// ── Cluster tracking ───────────────────────────────────────────────
ClusterInfo g_clusters[MAX_CLUSTERS_ABSOLUTE];
int         g_nextClusterSeq = 1;    // Next sequential cluster ID

// ── Indicator handles ──────────────────────────────────────────────
int         g_handleATR  = INVALID_HANDLE;
int         g_handleADX  = INVALID_HANDLE;
int         g_handleEMA  = INVALID_HANDLE;
int         g_handleBB   = INVALID_HANDLE;

// ── Indicator buffers (latest values) ──────────────────────────────
double      g_currentATR        = 0;
double      g_currentADX        = 0;
double      g_currentEMA        = 0;
double      g_previousEMA       = 0;
double      g_bbUpper           = 0;
double      g_bbLower           = 0;
double      g_bbMiddle          = 0;

// ── Derived values ─────────────────────────────────────────────────
double      g_currentGridStep   = 0;
double      g_pointValue        = 0;
ENUM_GRID_MODE g_currentMode    = MODE_NEUTRAL;
ENUM_CLUSTER_DIRECTION g_trendDirection = DIR_NONE;

double      g_peakEquity = 0;  // Peak equity for protection mode drawdown tracking

// ── Risk state ─────────────────────────────────────────────────────
double      g_startEquity       = 0;
bool        g_killSwitchActive  = false;
bool        g_protectionModeActive = false;
bool        g_weekendSafetyExecuted = false;
bool        g_mondayUnwindExecuted  = false;
datetime    g_killSwitchCooldownUntil = 0;

// ── News filter cache ──────────────────────────────────────────────
bool        g_isNewsWindow      = false;
datetime    g_lastNewsCheck     = 0;

// ── New bar detection ──────────────────────────────────────────────
datetime    g_lastBarTimeM15    = 0;
datetime    g_lastBarTimeATR    = 0;
datetime    g_lastBarTimeADX    = 0;

// ── Cluster open cooldown ──────────────────────────────────────────
datetime    g_lastClusterOpenBar = 0;  // Prevent multiple clusters on same bar

// ── Session time cache (converted to broker time) ──────────────────
int         g_sessionStartSeconds  = 0;
int         g_newClusterCutoffSeconds = 0;
int         g_sessionCloseSeconds  = 0;
int         g_fridayCloseSeconds   = 0;


//+------------------------------------------------------------------+
//| MODULE A: INITIALIZATION                                           |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // ── Step 1: Validate inputs ─────────────────────────────────────
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);
   
   // ── Step 2: Verify account type ─────────────────────────────────
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("ERROR: Account must be hedging type. Current mode: ",
            AccountInfoInteger(ACCOUNT_MARGIN_MODE));
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   // ── Step 3: Verify symbol trading enabled ───────────────────────
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("ERROR: Trading disabled for ", _Symbol);
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   // ── Step 4: Calculate point value ───────────────────────────────
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tickSize == 0 || tickValue == 0)
   {
      Print("ERROR: Cannot read tick value/size for ", _Symbol);
      return(INIT_FAILED);
   }
   
   g_pointValue = tickValue / tickSize;
   Print("Point value calculated: ", DoubleToString(g_pointValue, 4), " per lot per point");
   
   // ── Step 5: Initialize indicator handles ────────────────────────
   if(!InitializeIndicators())
      return(INIT_FAILED);
   
   // ── Step 6: Load persisted state (protection mode, start equity) 
   LoadState();
   
   // ── Step 7: Handle protection mode ──────────────────────────────
   if(g_protectionModeActive)
   {
      if(ResetProtectionMode)
      {
         // Manual reset requested
         g_protectionModeActive = false;
         g_startEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         if(g_peakEquity <= 0)
            g_peakEquity = g_startEquity;
         GlobalVariableDel(GetGlobalVarName("ProtectionMode"));
         GlobalVariableSet(GetGlobalVarName("StartEquity"), g_startEquity);
         Print("Protection mode RESET. New start equity: $", 
               DoubleToString(g_startEquity, 2));
         LogToCSV("PROTECTION_RESET", 0, TIER_ID, 0, "Manual reset",
                  0, 0, "New StartEquity=" + DoubleToString(g_startEquity, 2));
      }
      else
      {
         Print("WARNING: Account protection mode is ACTIVE. EA is locked.");
         Print("Set ResetProtectionMode=true and reload EA to resume trading.");
         return(INIT_SUCCEEDED); // EA loads but won't trade
      }
   }
   
   // ── Step 8: Set start equity if first run ───────────────────────
   if(g_startEquity == 0)
   {
      g_startEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(GetGlobalVarName("StartEquity"), g_startEquity);
      Print("Start equity set: $", DoubleToString(g_startEquity, 2));
   }
   
   // ── Step 9: Initialize cluster array ────────────────────────────
   InitializeClusters();
   
   // ── Step 10: Convert session times to broker seconds ────────────
   CalculateSessionTimes();
   
   // ── Step 11: Reconstruct state from open positions (if restart) ─
   ReconstructClustersFromPositions();
   
   // ── Step 12: Initialization complete ────────────────────────────
   Print("═══════════════════════════════════════════════════");
   Print("Grid EA Initialized — Intraday Tier");
   Print("Symbol: ", _Symbol);
   Print("Account equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("Start equity: $", DoubleToString(g_startEquity, 2));
   Print("Magic base: ", MagicBase);
   Print("Point value: ", DoubleToString(g_pointValue, 4));
   Print("Broker GMT offset: ", BrokerGMTOffset);
   Print("═══════════════════════════════════════════════════");
   
   // ── Diagnostic: print initial market state ──────────────────────
   DiagnosticPrintMarketState();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // ── Save state before shutdown ──────────────────────────────────
   SaveState();
   
   // ── Release indicator handles ───────────────────────────────────
   if(g_handleATR != INVALID_HANDLE)  { IndicatorRelease(g_handleATR); g_handleATR = INVALID_HANDLE; }
   if(g_handleADX != INVALID_HANDLE)  { IndicatorRelease(g_handleADX); g_handleADX = INVALID_HANDLE; }
   if(g_handleEMA != INVALID_HANDLE)  { IndicatorRelease(g_handleEMA); g_handleEMA = INVALID_HANDLE; }
   if(g_handleBB  != INVALID_HANDLE)  { IndicatorRelease(g_handleBB);  g_handleBB  = INVALID_HANDLE; }
   
   Print("Grid EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Validate all input parameters                                      |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   bool valid = true;
   
   // V1: ADX thresholds must be ordered
   if(ADXRangeThreshold >= ADXTrendThreshold)
   {
      Print("ERROR [V1]: ADXRangeThreshold (", ADXRangeThreshold, 
            ") must be less than ADXTrendThreshold (", ADXTrendThreshold, ")");
      valid = false;
   }
   
   // V2: Grid step floor < cap
   if(GridStepFloor >= GridStepCap)
   {
      Print("ERROR [V2]: GridStepFloor (", GridStepFloor, 
            ") must be less than GridStepCap (", GridStepCap, ")");
      valid = false;
   }
   
   // V3: Leg scaling start within MaxLegs
   if(LegScalingStart > MaxLegs)
   {
      Print("ERROR [V3]: LegScalingStart (", LegScalingStart, 
            ") must not exceed MaxLegs (", MaxLegs, ")");
      valid = false;
   }
   
   // V4: Leg scaling factor within max multiplier
   if(LegScalingFactor > MAX_LOT_MULTIPLIER)
   {
      Print("ERROR [V4]: LegScalingFactor (", LegScalingFactor, 
            ") exceeds MAX_LOT_MULTIPLIER (", MAX_LOT_MULTIPLIER, ")");
      valid = false;
   }
   
   // V5: Session times chronologically ordered
   int startSec  = SessionStartHour * 3600 + SessionStartMinute * 60;
   int cutoffSec = NewClusterCutoffHour * 3600 + NewClusterCutoffMinute * 60;
   int closeSec  = SessionCloseHour * 3600 + SessionCloseMinute * 60;
   
   if(!(startSec < cutoffSec && cutoffSec < closeSec))
   {
      Print("ERROR [V5]: Session times must be ordered: Start (", 
            SessionStartHour, ":", SessionStartMinute, ") < Cutoff (", 
            NewClusterCutoffHour, ":", NewClusterCutoffMinute, ") < Close (",
            SessionCloseHour, ":", SessionCloseMinute, ")");
      valid = false;
   }
   
   // V6: Friday close at or before session close
   int fridaySec = FridayCloseHour * 3600 + FridayCloseMinute * 60;
   if(fridaySec > closeSec)
   {
      Print("ERROR [V6]: FridayClose (", FridayCloseHour, ":", FridayCloseMinute,
            ") must be at or before SessionClose (", SessionCloseHour, ":", SessionCloseMinute, ")");
      valid = false;
   }
   
   // V7: Kill switch before protection mode
   if(KillSwitchPct >= ProtectionDrawdownPct)
   {
      Print("ERROR [V7]: KillSwitchPct (", KillSwitchPct, 
            ") must be less than ProtectionDrawdownPct (", ProtectionDrawdownPct, ")");
      valid = false;
   }
   
   // V8: Portfolio heat within limit
   if(RiskPerCluster * MaxConcurrentClusters > MAX_PORTFOLIO_HEAT_PCT + 0.001) // small epsilon for floating point
   {
      Print("ERROR [V8]: Total portfolio heat (", RiskPerCluster * MaxConcurrentClusters,
            ") exceeds MAX_PORTFOLIO_HEAT_PCT (", MAX_PORTFOLIO_HEAT_PCT, ")");
      valid = false;
   }
   
   // V9: Valid GMT offset
   if(BrokerGMTOffset < -12 || BrokerGMTOffset > 12)
   {
      Print("ERROR [V9]: Invalid BrokerGMTOffset (", BrokerGMTOffset, "). Must be -12 to +12.");
      valid = false;
   }
   
   // V10: Range checks on numeric inputs
   if(RiskPerCluster < 0.01 || RiskPerCluster > 0.05)
   {
      Print("ERROR [V10]: RiskPerCluster (", RiskPerCluster, ") out of range 0.01–0.05");
      valid = false;
   }
   
   if(MaxConcurrentClusters < 1 || MaxConcurrentClusters > MAX_CLUSTERS_ABSOLUTE)
   {
      Print("ERROR [V10]: MaxConcurrentClusters (", MaxConcurrentClusters, 
            ") out of range 1–", MAX_CLUSTERS_ABSOLUTE);
      valid = false;
   }
   
   if(MaxLegs < 3 || MaxLegs > MAX_LEGS_ABSOLUTE)
   {
      Print("ERROR [V10]: MaxLegs (", MaxLegs, ") out of range 3–", MAX_LEGS_ABSOLUTE);
      valid = false;
   }
   
   if(GridStepMultiplier < 0.15 || GridStepMultiplier > 0.40)
   {
      Print("ERROR [V10]: GridStepMultiplier (", GridStepMultiplier, ") out of range 0.15–0.40");
      valid = false;
   }
   
   if(TPMultiplier < 1.0 || TPMultiplier > 3.0)
   {
      Print("ERROR [V10]: TPMultiplier (", TPMultiplier, ") out of range 1.0–3.0");
      valid = false;
   }
   
   if(ATRPeriod < 7 || ATRPeriod > 30)
   {
      Print("ERROR [V10]: ATRPeriod (", ATRPeriod, ") out of range 7–30");
      valid = false;
   }
   
   if(ADXPeriod < 7 || ADXPeriod > 30)
   {
      Print("ERROR [V10]: ADXPeriod (", ADXPeriod, ") out of range 7–30");
      valid = false;
   }
   
   // V11: LegScalingStart valid
   if(LegScalingStart < 3 || LegScalingStart > MAX_LEGS_ABSOLUTE)
   {
      Print("ERROR [V11]: LegScalingStart (", LegScalingStart, ") out of range 3–", MAX_LEGS_ABSOLUTE);
      valid = false;
   }
   
   // V12: Hedge lock parameters
   if(HedgeLockTriggerMultiplier < 1.5 || HedgeLockTriggerMultiplier > 3.0)
   {
      Print("ERROR [V12]: HedgeLockTriggerMultiplier (", HedgeLockTriggerMultiplier, 
            ") out of range 1.5–3.0");
      valid = false;
   }
   
   if(HedgeUnlockMultiplier < 0.5 || HedgeUnlockMultiplier > 2.0)
   {
      Print("ERROR [V12]: HedgeUnlockMultiplier (", HedgeUnlockMultiplier, 
            ") out of range 0.5–2.0");
      valid = false;
   }
   
   if(HedgeForceCloseMultiplier < 0.5 || HedgeForceCloseMultiplier > 2.0)
   {
      Print("ERROR [V12]: HedgeForceCloseMultiplier (", HedgeForceCloseMultiplier, 
            ") out of range 0.5–2.0");
      valid = false;
   }
   
   // V13: ATR suspension percentage
   if(SuspendATRPctThreshold < 0.5 || SuspendATRPctThreshold > 20.0)
   {
      Print("ERROR [V13]: SuspendATRPctThreshold (", SuspendATRPctThreshold, ") out of range 0.5–20.0%");
      valid = false;
   }
   
   if(valid)
      Print("All input parameters validated successfully.");
   
   return valid;
}

//+------------------------------------------------------------------+
//| Initialize all indicator handles                                   |
//+------------------------------------------------------------------+
bool InitializeIndicators()
{
   // ── ATR ─────────────────────────────────────────────────────────
   g_handleATR = iATR(_Symbol, ATRTimeframe, ATRPeriod);
   if(g_handleATR == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR(", ATRPeriod, ") handle on ", 
            EnumToString(ATRTimeframe));
      return false;
   }
   
   // ── ADX ─────────────────────────────────────────────────────────
   g_handleADX = iADX(_Symbol, ADXTimeframe, ADXPeriod);
   if(g_handleADX == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ADX(", ADXPeriod, ") handle on ",
            EnumToString(ADXTimeframe));
      return false;
   }
   
   // ── EMA (trend direction) ───────────────────────────────────────
   g_handleEMA = iMA(_Symbol, TrendEMATimeframe, TrendEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_handleEMA == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA(", TrendEMAPeriod, ") handle on ",
            EnumToString(TrendEMATimeframe));
      return false;
   }
   
   // ── Bollinger Bands (range mode entry) ──────────────────────────
   g_handleBB = iBands(_Symbol, BBTimeframe, BBPeriod, 0, BBDeviation, PRICE_CLOSE);
   if(g_handleBB == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create BB(", BBPeriod, ",", BBDeviation, ") handle on ",
            EnumToString(BBTimeframe));
      return false;
   }
   
   // ── Wait for indicators to calculate ────────────────────────────
   int maxWait = 50; // 50 × 100ms = 5 seconds max
   int waited = 0;
   
   while(waited < maxWait)
   {
      bool allReady = true;
      
      if(BarsCalculated(g_handleATR) < MIN_BARS_FOR_INDICATOR) allReady = false;
      if(BarsCalculated(g_handleADX) < MIN_BARS_FOR_INDICATOR) allReady = false;
      if(BarsCalculated(g_handleEMA) < MIN_BARS_FOR_INDICATOR) allReady = false;
      if(BarsCalculated(g_handleBB)  < MIN_BARS_FOR_INDICATOR) allReady = false;
      
      if(allReady) break;
      
      Sleep(100);
      waited++;
   }
   
   if(waited >= maxWait)
   {
      Print("WARNING: Indicators may not have sufficient data. ",
            "ATR bars: ", BarsCalculated(g_handleATR),
            ", ADX bars: ", BarsCalculated(g_handleADX),
            ", EMA bars: ", BarsCalculated(g_handleEMA),
            ", BB bars: ", BarsCalculated(g_handleBB));
      // Continue anyway — indicators may populate on next bars
   }
   
   Print("Indicator handles created: ATR=", g_handleATR, 
         " ADX=", g_handleADX, " EMA=", g_handleEMA, " BB=", g_handleBB);
   
   return true;
}

//+------------------------------------------------------------------+
//| Initialize cluster array to IDLE                                   |
//+------------------------------------------------------------------+
void InitializeClusters()
{
   for(int i = 0; i < MAX_CLUSTERS_ABSOLUTE; i++)
      g_clusters[i].Reset();
   
   Print("Cluster array initialized: ", MAX_CLUSTERS_ABSOLUTE, " slots available, ",
         MaxConcurrentClusters, " max concurrent.");
}

//+------------------------------------------------------------------+
//| Calculate session times in broker server seconds-since-midnight    |
//+------------------------------------------------------------------+
void CalculateSessionTimes()
{
   g_sessionStartSeconds     = (SessionStartHour + BrokerGMTOffset) * 3600 
                              + SessionStartMinute * 60;
   g_newClusterCutoffSeconds = (NewClusterCutoffHour + BrokerGMTOffset) * 3600 
                              + NewClusterCutoffMinute * 60;
   g_sessionCloseSeconds     = (SessionCloseHour + BrokerGMTOffset) * 3600 
                              + SessionCloseMinute * 60;
   g_fridayCloseSeconds      = (FridayCloseHour + BrokerGMTOffset) * 3600 
                              + FridayCloseMinute * 60;
   
   // Handle day wrap (e.g., UTC 2:00 with GMT+3 broker = 5:00 broker time)
   // Negative values wrap to previous day — not handled here since
   // session start is always early morning and offset is typically 0–3
   
   Print("Session times (broker seconds): Start=", g_sessionStartSeconds,
         " Cutoff=", g_newClusterCutoffSeconds,
         " Close=", g_sessionCloseSeconds,
         " FridayClose=", g_fridayCloseSeconds);
}

//+------------------------------------------------------------------+
//| Generate global variable name with magic base prefix               |
//+------------------------------------------------------------------+
string GetGlobalVarName(string suffix)
{
   return "GridEA_" + IntegerToString(MagicBase) + "_" + suffix;
}

//+------------------------------------------------------------------+
//| MODULE B: MARKET STATE (Gate 2 — stubs)                            |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| MODULE B: MARKET STATE                                             |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Update all market state indicators                                 |
//| Called once per new M15 bar (and on ATR/ADX timeframe bars)        |
//+------------------------------------------------------------------+
void UpdateMarketState()
{
   // ── Read raw indicator values ───────────────────────────────────
   double prevATR = g_currentATR;
   ENUM_GRID_MODE prevMode = g_currentMode;
   
   g_currentATR = GetCurrentATR();
   g_currentADX = GetCurrentADX();
   ReadEMAValues();
   ReadBBValues();
   
   // ── Calculate derived values ────────────────────────────────────
   g_currentGridStep = GetCurrentGridStep();
   g_currentMode     = GetCurrentMode();
   g_trendDirection  = GetTrendDirection();
   
   // ── Log state changes ───────────────────────────────────────────
   if(prevMode != g_currentMode)
   {
      LogToCSV("MODE_SWITCH", 0, TIER_ID, 0, 
               EnumToString(prevMode) + "->" + EnumToString(g_currentMode),
               SymbolInfoDouble(_Symbol, SYMBOL_BID), 0,
               "ADX=" + DoubleToString(g_currentADX, 1));
   }
   
   // ── Debug output (remove or reduce frequency in production) ─────
   static int updateCount = 0;
   updateCount++;
   
   // Print every 4th update (~1 hour at M15) to avoid log spam
   if(updateCount % 4 == 0)
   {
      Print("MarketState | ATR: $", DoubleToString(g_currentATR, 2),
            " | ADX: ", DoubleToString(g_currentADX, 1),
            " | Step: $", DoubleToString(g_currentGridStep, 2),
            " | Mode: ", EnumToString(g_currentMode),
            " | Trend: ", EnumToString(g_trendDirection),
            " | EMA: ", DoubleToString(g_currentEMA, 2),
            " | BB: ", DoubleToString(g_bbLower, 2), "/", 
            DoubleToString(g_bbMiddle, 2), "/", 
            DoubleToString(g_bbUpper, 2));
   }
}

//+------------------------------------------------------------------+
//| Read current ATR(14) value from D1 timeframe                       |
//+------------------------------------------------------------------+
double GetCurrentATR()
{
   double buffer[];
   ArraySetAsSeries(buffer, true);
   
   int copied = CopyBuffer(g_handleATR, 0, 0, 2, buffer);
   
   if(copied < 1)
   {
      Print("WARNING: Failed to read ATR buffer. Copied: ", copied, 
            " Error: ", GetLastError());
      return g_currentATR; // Return previous value as fallback
   }
   
   double atr = buffer[0];
   
   // Sanity check: ATR should be positive and within reasonable range for XAUUSD
   if(atr <= 0 || atr == EMPTY_VALUE)
   {
      Print("WARNING: ATR returned invalid value: ", atr, ". Using previous: ", g_currentATR);
      return g_currentATR;
   }
   
   return atr;
}

//+------------------------------------------------------------------+
//| Read current ADX(14) main line from H1 timeframe                   |
//+------------------------------------------------------------------+
double GetCurrentADX()
{
   double buffer[];
   ArraySetAsSeries(buffer, true);
   
   // Buffer 0 = Main ADX line
   int copied = CopyBuffer(g_handleADX, 0, 0, 2, buffer);
   
   if(copied < 1)
   {
      Print("WARNING: Failed to read ADX buffer. Copied: ", copied,
            " Error: ", GetLastError());
      return g_currentADX; // Return previous value as fallback
   }
   
   double adx = buffer[0];
   
   // Sanity check: ADX ranges 0–100
   if(adx < 0 || adx > 100 || adx == EMPTY_VALUE)
   {
      Print("WARNING: ADX returned invalid value: ", adx, ". Using previous: ", g_currentADX);
      return g_currentADX;
   }
   
   return adx;
}

//+------------------------------------------------------------------+
//| Read current and previous EMA values for slope detection           |
//+------------------------------------------------------------------+
void ReadEMAValues()
{
   double buffer[];
   ArraySetAsSeries(buffer, true);
   
   // Need at least 2 values: current [0] and previous [1] for slope
   int copied = CopyBuffer(g_handleEMA, 0, 0, 3, buffer);
   
   if(copied < 2)
   {
      Print("WARNING: Failed to read EMA buffer. Copied: ", copied,
            " Error: ", GetLastError());
      return; // Keep previous values
   }
   
   if(buffer[0] == EMPTY_VALUE || buffer[1] == EMPTY_VALUE)
   {
      Print("WARNING: EMA returned EMPTY_VALUE. Keeping previous values.");
      return;
   }
   
   g_currentEMA  = buffer[0];  // Current bar EMA
   g_previousEMA = buffer[1];  // Previous bar EMA
}

//+------------------------------------------------------------------+
//| Read Bollinger Band values (upper, middle, lower)                  |
//+------------------------------------------------------------------+
void ReadBBValues()
{
   double bufferBase[];    // Buffer 0 = Base line (middle)
   double bufferUpper[];   // Buffer 1 = Upper band
   double bufferLower[];   // Buffer 2 = Lower band
   
   ArraySetAsSeries(bufferBase, true);
   ArraySetAsSeries(bufferUpper, true);
   ArraySetAsSeries(bufferLower, true);
   
   int copiedBase  = CopyBuffer(g_handleBB, 0, 0, 2, bufferBase);
   int copiedUpper = CopyBuffer(g_handleBB, 1, 0, 2, bufferUpper);
   int copiedLower = CopyBuffer(g_handleBB, 2, 0, 2, bufferLower);
   
   if(copiedBase < 1 || copiedUpper < 1 || copiedLower < 1)
   {
      Print("WARNING: Failed to read BB buffers. Base:", copiedBase,
            " Upper:", copiedUpper, " Lower:", copiedLower,
            " Error: ", GetLastError());
      return; // Keep previous values
   }
   
   if(bufferBase[0] == EMPTY_VALUE || bufferUpper[0] == EMPTY_VALUE || bufferLower[0] == EMPTY_VALUE)
   {
      Print("WARNING: BB returned EMPTY_VALUE. Keeping previous values.");
      return;
   }
   
   g_bbMiddle = bufferBase[0];
   g_bbUpper  = bufferUpper[0];
   g_bbLower  = bufferLower[0];
}

//+------------------------------------------------------------------+
//| Calculate grid step with floor, cap, and ATR scaling               |
//+------------------------------------------------------------------+
double GetCurrentGridStep()
{
   if(g_currentATR <= 0)
      return GridStepFloor; // Safety: return floor if ATR not yet available
   
   double rawStep = g_currentATR * GridStepMultiplier;
   double clampedStep = MathMax(GridStepFloor, MathMin(GridStepCap, rawStep));
   
   return clampedStep;
}

//+------------------------------------------------------------------+
//| Determine current grid mode from ADX value                         |
//| MODE_RANGE:       ADX < ADXRangeThreshold                          |
//| MODE_NEUTRAL:     ADXRangeThreshold <= ADX <= ADXTrendThreshold    |
//| MODE_DIRECTIONAL: ADX > ADXTrendThreshold                          |
//+------------------------------------------------------------------+
ENUM_GRID_MODE GetCurrentMode()
{
   if(g_currentADX <= 0)
      return MODE_NEUTRAL; // Safety: neutral if ADX not yet available
   
   if(g_currentADX < ADXRangeThreshold)
      return MODE_RANGE;
   
   if(g_currentADX > ADXTrendThreshold)
      return MODE_DIRECTIONAL;
   
   return MODE_NEUTRAL;
}

//+------------------------------------------------------------------+
//| Determine trend direction from EMA slope                           |
//| Compares current EMA to previous EMA                               |
//| Minimum slope threshold prevents noise from triggering direction   |
//+------------------------------------------------------------------+
ENUM_CLUSTER_DIRECTION GetTrendDirection()
{
   if(g_currentEMA <= 0 || g_previousEMA <= 0)
      return DIR_NONE; // Safety: no direction if EMA not available
   
   double slope = g_currentEMA - g_previousEMA;
   
   // Minimum slope threshold: 0.5% of current grid step
   // Prevents near-flat EMA from giving false directional signals
   double minSlope = g_currentGridStep * 0.005;
   
   // At $9.92 grid step: minSlope = $0.0496
   // EMA must move at least ~$0.05 per bar to register as trending
   
   if(slope > minSlope)
      return DIR_LONG;
   
   if(slope < -minSlope)
      return DIR_SHORT;
   
   return DIR_NONE; // EMA is flat — no clear direction
}

//+------------------------------------------------------------------+
//| Check for Bollinger Band touch entry (Range Mode only)             |
//| Returns true if price has touched or crossed a band                |
//| Sets dir to LONG (lower band touch) or SHORT (upper band touch)    |
//+------------------------------------------------------------------+
bool IsBollingerEntry(ENUM_CLUSTER_DIRECTION &dir)
{
   dir = DIR_NONE;
   
   // Only valid in Range Mode
   if(g_currentMode != MODE_RANGE)
      return false;
   
   // BB values must be valid
   if(g_bbUpper <= 0 || g_bbLower <= 0 || g_bbMiddle <= 0)
      return false;
   
   // BB must have meaningful width (not collapsed)
   double bbWidth = g_bbUpper - g_bbLower;
   if(bbWidth < g_currentGridStep * 0.5)
   {
      // Bands too narrow — squeeze condition but insufficient room for grid
      return false;
   }
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   if(bid <= 0 || ask <= 0)
      return false;
   
   // ── Lower band touch → LONG entry ──────────────────────────────
   // Price at or below lower band (using ask for buy entry comparison)
   if(ask <= g_bbLower)
   {
      dir = DIR_LONG;
      return true;
   }
   
   // ── Upper band touch → SHORT entry ─────────────────────────────
   // Price at or above upper band (using bid for sell entry comparison)
   if(bid >= g_bbUpper)
   {
      dir = DIR_SHORT;
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check for pullback entry in trend direction (Directional Mode)     |
//|                                                                    |
//| Logic:                                                             |
//| In an uptrend (DIR_LONG): price has pulled back to or below EMA    |
//|   AND the current bar's close is back above EMA (resumption)       |
//| In a downtrend (DIR_SHORT): price has pulled back to or above EMA  |
//|   AND the current bar's close is back below EMA (resumption)       |
//|                                                                    |
//| This ensures we enter on pullback COMPLETION, not during the       |
//| pullback itself (which could continue further).                    |
//+------------------------------------------------------------------+
bool IsPullbackEntry()
{
   // Only valid in Directional Mode
   if(g_currentMode != MODE_DIRECTIONAL)
      return false;
   
   if(g_trendDirection == DIR_NONE)
      return false;
   
   if(g_currentEMA <= 0)
      return false;
   
   // Get current price data
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(bid <= 0)
      return false;
   
   // Get previous bar's close and low/high to detect the pullback
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   int copied = CopyRates(_Symbol, TrendEMATimeframe, 0, 3, rates);
   if(copied < 3)
      return false;
   
   // rates[0] = current (forming) bar
   // rates[1] = last closed bar
   // rates[2] = two bars ago
   
   if(g_trendDirection == DIR_LONG)
   {
      // ── LONG pullback entry ──────────────────────────────────────
      // Condition 1: Previous bar's low touched or went below EMA (pullback occurred)
      bool pullbackOccurred = (rates[1].low <= g_currentEMA);
      
      // Condition 2: Previous bar closed above EMA (pullback completed, trend resuming)
      bool resumption = (rates[1].close > g_currentEMA);
      
      // Condition 3: Current price is still near EMA (not already run away)
      // "Near" = within 1 grid step above EMA
      bool nearEMA = (bid > g_currentEMA && bid < g_currentEMA + g_currentGridStep);
      
      return (pullbackOccurred && resumption && nearEMA);
   }
   else if(g_trendDirection == DIR_SHORT)
   {
      // ── SHORT pullback entry ─────────────────────────────────────
      // Condition 1: Previous bar's high touched or went above EMA (pullback occurred)
      bool pullbackOccurred = (rates[1].high >= g_currentEMA);
      
      // Condition 2: Previous bar closed below EMA (pullback completed, trend resuming)
      bool resumption = (rates[1].close < g_currentEMA);
      
      // Condition 3: Current price is still near EMA (not already run away)
      bool nearEMA = (bid < g_currentEMA && bid > g_currentEMA - g_currentGridStep);
      
      return (pullbackOccurred && resumption && nearEMA);
   }
   
   return false;
}
//+------------------------------------------------------------------+
//| DIAGNOSTIC: Force market state update and print all values         |
//| Call from OnInit() or via chart button for testing                  |
//+------------------------------------------------------------------+
void DiagnosticPrintMarketState()
{
   // Force-read all indicators regardless of bar state
   g_currentATR = GetCurrentATR();
   g_currentADX = GetCurrentADX();
   ReadEMAValues();
   ReadBBValues();
   g_currentGridStep = GetCurrentGridStep();
   g_currentMode     = GetCurrentMode();
   g_trendDirection  = GetTrendDirection();
   
   Print("╔══════════════════════════════════════════════════════╗");
   Print("║           MARKET STATE DIAGNOSTIC                    ║");
   Print("╠══════════════════════════════════════════════════════╣");
   Print("║ Bid:          $", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), 2));
   Print("║ Ask:          $", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), 2));
   Print("║ Spread:       ", SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), " points ($",
         DoubleToString(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point, 2), ")");
   Print("╠══════════════════════════════════════════════════════╣");
   Print("║ ATR(", ATRPeriod, ",", EnumToString(ATRTimeframe), "): $", 
         DoubleToString(g_currentATR, 2));
   Print("║ ADX(", ADXPeriod, ",", EnumToString(ADXTimeframe), "): ", 
         DoubleToString(g_currentADX, 1));
   Print("║ EMA(", TrendEMAPeriod, ",", EnumToString(TrendEMATimeframe), "): $", 
         DoubleToString(g_currentEMA, 2), 
         "  prev: $", DoubleToString(g_previousEMA, 2),
         "  slope: $", DoubleToString(g_currentEMA - g_previousEMA, 4));
   Print("║ BB(", BBPeriod, ",", DoubleToString(BBDeviation, 1), ",", 
         EnumToString(BBTimeframe), "): ",
         "Low $", DoubleToString(g_bbLower, 2),
         " | Mid $", DoubleToString(g_bbMiddle, 2),
         " | High $", DoubleToString(g_bbUpper, 2));
   Print("║ BB Width:     $", DoubleToString(g_bbUpper - g_bbLower, 2));
   Print("╠══════════════════════════════════════════════════════╣");
   Print("║ Grid Step:    $", DoubleToString(g_currentGridStep, 2),
         "  (raw: $", DoubleToString(g_currentATR * GridStepMultiplier, 2), 
         ", floor: $", DoubleToString(GridStepFloor, 2),
         ", cap: $", DoubleToString(GridStepCap, 2), ")");
   Print("║ Grid Mode:    ", EnumToString(g_currentMode));
   Print("║ Trend Dir:    ", EnumToString(g_trendDirection));
   double diagMidPrice = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
   double diagAtrPct = (diagMidPrice > 0) ? (g_currentATR / diagMidPrice) * 100.0 : 0.0;
   Print("║ ATR Suspended: ", (diagAtrPct > SuspendATRPctThreshold) ? "YES" : "NO",
         "  (ATR: ", DoubleToString(diagAtrPct, 2), "% of price, threshold: ", 
         DoubleToString(SuspendATRPctThreshold, 2), "%)");
   Print("╠══════════════════════════════════════════════════════╣");
   
   // Entry signal checks
   ENUM_CLUSTER_DIRECTION bbDir = DIR_NONE;
   bool bbEntry = IsBollingerEntry(bbDir);
   bool pbEntry = IsPullbackEntry();
   
   Print("║ BB Entry:     ", bbEntry ? "YES" : "NO", 
         "  Direction: ", EnumToString(bbDir));
   Print("║ Pullback Entry: ", pbEntry ? "YES" : "NO",
         "  (requires DIR mode + trend + near EMA)");
   Print("║ Spread viable: ", 
         (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point / g_currentGridStep <= SPREAD_TO_STEP_MAX_RATIO) 
         ? "YES" : "NO",
         "  (ratio: ", DoubleToString(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point / MathMax(g_currentGridStep, 0.01) * 100, 1), "%)");
   Print("╚══════════════════════════════════════════════════════╝");
}

//+------------------------------------------------------------------+
//| MODULE C: CLUSTER MANAGEMENT                                       |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Master pre-check for opening new clusters                          |
//| Returns true only if ALL conditions allow a new cluster            |
//+------------------------------------------------------------------+
bool CanOpenNewCluster()
{
   // ── Check 1: Session window ─────────────────────────────────────
   if(!IsInSession())
      return false;
   
   // ── Check 2: Before cutoff time ─────────────────────────────────
   if(!IsBeforeCutoff())
      return false;
   
   // ── Check 3: ATR not suspended ──────────────────────────────────
   if(IsSuspended())
      return false;
   
   // ── Check 4: Kill switch not active ───────────���─────────────────
   if(g_killSwitchActive)
      return false;
   
   // ── Check 5: Protection mode not active ─────────────────────────
   if(g_protectionModeActive)
      return false;
   
   // ── Check 6: Not in neutral mode ────────────────────────────────
   if(g_currentMode == MODE_NEUTRAL)
      return false;
   
   // ── Check 7: Grid step is valid ─────────────────────────────────
   if(g_currentGridStep <= 0)
      return false;
   
   // ── Check 8: News filter ────────────────────────────────────────
   if(IsNewsWindow())
      return false;
   
   // ── Check 9: Spread viability ───────────────────────────────────
   if(!CheckSpreadViability())
      return false;
   
   // ── Check 10: Portfolio heat ────────────────────────────────────
   if(GetPortfolioHeat() >= MAX_PORTFOLIO_HEAT_PCT)
      return false;
   
   // ── Check 11: Free cluster slot exists ──────────────────────────
   if(FindFreeClusterSlot() < 0)
      return false;
   
   // ── Check 12: Sufficient ATR/ADX data ───────────────────────────
   if(g_currentATR <= 0 || g_currentADX <= 0)
      return false;

   // ── Check 13: Minimum equity pre-flight ────────────────────────
   //    Estimate whether CalculateBaseLot() can produce >= volumeMin
   //    to prevent per-tick spam when equity is too low.
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double volumeMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      double totalWeightedLegs = GetTotalWeightedLegs();
      double maxAdverseSteps = 3.0;
      
      if(contractSize > 0 && totalWeightedLegs > 0 && g_currentGridStep > 0 && RiskPerCluster > 0)
      {
         double minEquityNeeded = volumeMin * totalWeightedLegs * maxAdverseSteps 
                                  * g_currentGridStep * contractSize / RiskPerCluster;
         if(equity < minEquityNeeded)
         {
            // Log once per H1 bar, not every tick
            static datetime lastInsufficientEquityLog = 0;
            datetime currentBar = iTime(_Symbol, PERIOD_H1, 0);
            if(currentBar != lastInsufficientEquityLog)
            {
               lastInsufficientEquityLog = currentBar;
               Print("INFO: Equity ($", DoubleToString(equity, 2), 
                     ") below minimum required ($", DoubleToString(minEquityNeeded, 2),
                     ") for grid parameters. Skipping cluster open.");
            }
            return false;
         }
      }
   }

   // ── Check 14: Cooldown — one cluster per M15 bar ───────────────
   datetime currentBar = iTime(_Symbol, PERIOD_M15, 0);
   if(currentBar == g_lastClusterOpenBar)
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Find first available IDLE cluster slot                             |
//| Returns slot index (0-based) or -1 if none available              |
//+------------------------------------------------------------------+
int FindFreeClusterSlot()
{
   int activeCount = 0;
   int freeSlot = -1;
   
   for(int i = 0; i < MAX_CLUSTERS_ABSOLUTE; i++)
   {
      if(g_clusters[i].state != CLUSTER_IDLE)
         activeCount++;
      else if(freeSlot < 0)
         freeSlot = i;
   }
   
   // Enforce MaxConcurrentClusters
   if(activeCount >= MaxConcurrentClusters)
      return -1;
   
   return freeSlot;
}

//+------------------------------------------------------------------+
//| Open a new cluster — places the first leg                          |
//|                                                                    |
//| slotIndex: index in g_clusters array                               |
//| mode:      RANGE or DIRECTIONAL (frozen for cluster lifetime)      |
//| dir:       LONG or SHORT (frozen for cluster lifetime)             |
//+------------------------------------------------------------------+
bool OpenCluster(int slotIndex, ENUM_GRID_MODE mode, ENUM_CLUSTER_DIRECTION dir)
{
   // ── Validate slot ───────────────────────────────────────────────
   if(slotIndex < 0 || slotIndex >= MAX_CLUSTERS_ABSOLUTE)
   {
      Print("ERROR: Invalid cluster slot index: ", slotIndex);
      return false;
   }
   
   if(g_clusters[slotIndex].state != CLUSTER_IDLE)
   {
      Print("ERROR: Cluster slot ", slotIndex, " is not IDLE. State: ",
            EnumToString(g_clusters[slotIndex].state));
      return false;
   }
   
   // ── Freeze grid step at cluster open ────────────────────────────
   double gridStep = g_currentGridStep;
   if(gridStep <= 0)
   {
      Print("ERROR: Grid step is zero or negative: ", gridStep);
      return false;
   }
   
   // ── Calculate base lot ──────────────────────────────────────────
   double baseLot = CalculateBaseLot(gridStep);
   if(baseLot <= 0)
   {
      // Warning already throttled in CalculateBaseLot — no need to double-log
      return false;
   }
   
   // ── Check margin sufficiency ────────────────────────────────────
   if(!CheckMarginSufficiency(baseLot))
   {
      Print("WARNING: Cannot open cluster — insufficient margin.");
      return false;
   }
   
   // ── Build magic numbers ─────────────────────────────────────────
   int clusterSeq = GetNextClusterSeq();
   int magicBase  = BuildMagicNumber(dir, clusterSeq);
   int hedgeMagic = BuildHedgeMagic(magicBase);
   
   // ── Determine order type and TP ─────────────────────────────────
   ENUM_ORDER_TYPE orderType;
   double tp;
   double currentPrice;
   
   if(dir == DIR_LONG)
   {
      orderType    = ORDER_TYPE_BUY;
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      tp           = currentPrice + gridStep * TPMultiplier;
   }
   else
   {
      orderType    = ORDER_TYPE_SELL;
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      tp           = currentPrice - gridStep * TPMultiplier;
   }
   
   // Normalize TP to tick size
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0)
      tp = MathRound(tp / tickSize) * tickSize;
   
   // ── Get lot for first leg ───────────────────────────────────────
   double leg1Lot = GetLegLot(1, baseLot);
   
   // ── Send market order ───────────────────────────────────────────
   string comment = "Grid_" + EnumToString(mode) + "_" + EnumToString(dir) + 
                    "_C" + IntegerToString(clusterSeq) + "_L1";
   
   ulong ticket = 0;
   if(!SendMarketOrder(_Symbol, orderType, leg1Lot, magicBase, comment, tp, ticket))
   {
      Print("ERROR: Failed to open first leg for cluster ", clusterSeq);
      // Sequence was already incremented — that's OK, we just skip a number
      return false;
   }
   
   // ── Populate cluster info ───────────────────────────────────────
   ClusterInfo cluster;
   cluster.Reset();
   
   cluster.state      = CLUSTER_NORMAL;
   cluster.mode       = mode;
   cluster.direction  = dir;
   cluster.clusterSeq = clusterSeq;
   cluster.magicBase  = magicBase;
   cluster.hedgeMagic = hedgeMagic;
   cluster.gridStep   = gridStep;
   cluster.baseLot    = baseLot;
   cluster.tpDistance  = gridStep * TPMultiplier;
   cluster.legsOpened = 1;
   cluster.legsClosed = 0;
   cluster.locksActive = 0;
   cluster.openTime   = TimeCurrent();
   cluster.lockPrice  = 0;
   cluster.lockTime   = 0;
   
   // Get actual fill price from position
   double fillPrice = currentPrice; // Default to requested price
   if(PositionSelectByTicket(ticket))
      fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   
   cluster.lastLegPrice = fillPrice;
   
   if(dir == DIR_LONG)
   {
      cluster.totalLotsLong  = leg1Lot;
      cluster.totalLotsShort = 0;
   }
   else
   {
      cluster.totalLotsLong  = 0;
      cluster.totalLotsShort = leg1Lot;
   }
   
   // ── Populate leg 1 info ─────────────────────────────────────────
   cluster.legs[1].ticket     = ticket;
   cluster.legs[1].legNumber  = 1;
   cluster.legs[1].entryPrice = fillPrice;
   cluster.legs[1].lotSize    = leg1Lot;
   cluster.legs[1].tpPrice    = tp;
   cluster.legs[1].isOpen     = true;
   cluster.legs[1].isHedge    = false;
   cluster.legs[1].openTime   = TimeCurrent();
   cluster.legs[1].closeTime  = 0;
   cluster.legs[1].closePL    = 0;
   
   // ── Assign to slot ──────────────────────────────────────────────
   g_clusters[slotIndex] = cluster;
   
   Print("CLUSTER OPENED — Slot:", slotIndex,
         " Seq:", clusterSeq,
         " Mode:", EnumToString(mode),
         " Dir:", EnumToString(dir),
         " Step:$", DoubleToString(gridStep, 2),
         " BaseLot:", DoubleToString(baseLot, 2),
         " Leg1@$", DoubleToString(fillPrice, 2),
         " TP:$", DoubleToString(tp, 2),
         " Magic:", magicBase);
         
   // ── Set cooldown ────────────────────────────────────────────────
   g_lastClusterOpenBar = iTime(_Symbol, PERIOD_M15, 0);
   return true;
}

//+------------------------------------------------------------------+
//| Open next leg in an existing cluster                                |
//+------------------------------------------------------------------+
bool OpenNextLeg(int slotIndex)
{
   if(g_clusters[slotIndex].legsOpened >= MaxLegs)
      return false;
   
   int nextLegNum = g_clusters[slotIndex].legsOpened + 1;
   
   double legLot = GetLegLot(nextLegNum, g_clusters[slotIndex].baseLot);
   if(legLot <= 0)
   {
      Print("WARNING: Leg lot is zero for leg ", nextLegNum, 
            " of cluster ", g_clusters[slotIndex].clusterSeq);
      return false;
   }
   
   if(!CheckMarginSufficiency(legLot))
   {
      Print("WARNING: Insufficient margin for leg ", nextLegNum, 
            " of cluster ", g_clusters[slotIndex].clusterSeq);
      return false;
   }
   
   ENUM_ORDER_TYPE orderType;
   double tp;
   double currentPrice;
   
   if(g_clusters[slotIndex].direction == DIR_LONG)
   {
      orderType    = ORDER_TYPE_BUY;
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      tp           = currentPrice + g_clusters[slotIndex].gridStep * TPMultiplier;
   }
   else
   {
      orderType    = ORDER_TYPE_SELL;
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      tp           = currentPrice - g_clusters[slotIndex].gridStep * TPMultiplier;
   }
   
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0)
      tp = MathRound(tp / tickSize) * tickSize;
   
   string comment = "Grid_" + EnumToString(g_clusters[slotIndex].mode) + "_" + 
                    EnumToString(g_clusters[slotIndex].direction) +
                    "_C" + IntegerToString(g_clusters[slotIndex].clusterSeq) + 
                    "_L" + IntegerToString(nextLegNum);
   
   ulong ticket = 0;
   if(!SendMarketOrder(_Symbol, orderType, legLot, g_clusters[slotIndex].magicBase, 
                       comment, tp, ticket))
   {
      Print("ERROR: Failed to open leg ", nextLegNum, 
            " for cluster ", g_clusters[slotIndex].clusterSeq);
      return false;
   }
   
   double fillPrice = currentPrice;
   if(PositionSelectByTicket(ticket))
      fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   
   g_clusters[slotIndex].legsOpened++;
   g_clusters[slotIndex].lastLegPrice = fillPrice;
   
   if(g_clusters[slotIndex].direction == DIR_LONG)
      g_clusters[slotIndex].totalLotsLong += legLot;
   else
      g_clusters[slotIndex].totalLotsShort += legLot;
   
   g_clusters[slotIndex].legs[nextLegNum].ticket     = ticket;
   g_clusters[slotIndex].legs[nextLegNum].legNumber  = nextLegNum;
   g_clusters[slotIndex].legs[nextLegNum].entryPrice = fillPrice;
   g_clusters[slotIndex].legs[nextLegNum].lotSize    = legLot;
   g_clusters[slotIndex].legs[nextLegNum].tpPrice    = tp;
   g_clusters[slotIndex].legs[nextLegNum].isOpen     = true;
   g_clusters[slotIndex].legs[nextLegNum].isHedge    = false;
   g_clusters[slotIndex].legs[nextLegNum].openTime   = TimeCurrent();
   
   Print("LEG OPENED — Cluster:", g_clusters[slotIndex].clusterSeq,
         " Leg:", nextLegNum, "/", MaxLegs,
         " Lot:", DoubleToString(legLot, 2),
         " @$", DoubleToString(fillPrice, 2),
         " TP:$", DoubleToString(tp, 2));
   
   LogToCSV("LEG_OPEN", g_clusters[slotIndex].clusterSeq, TIER_ID,
            (int)g_clusters[slotIndex].direction, "Leg" + IntegerToString(nextLegNum),
            fillPrice, legLot,
            "TP=" + DoubleToString(tp, 2) + 
            " TotalLegs=" + IntegerToString(g_clusters[slotIndex].legsOpened));
   
   return true;
}

//+------------------------------------------------------------------+
//| Per-tick cluster management                                        |
//+------------------------------------------------------------------+
void ManageCluster(int slotIndex)
{
   if(g_clusters[slotIndex].state == CLUSTER_NORMAL)
   {
      CheckHedgeLock(slotIndex);
      
      if(g_clusters[slotIndex].state == CLUSTER_NORMAL)
      {
         CheckLegTPs(slotIndex);
         
         if(ShouldOpenNextLeg(slotIndex))
            OpenNextLeg(slotIndex);
         
         if(IsClusterComplete(slotIndex))
            g_clusters[slotIndex].state = CLUSTER_CLOSED;
      }
   }
   else if(g_clusters[slotIndex].state == CLUSTER_UNLOCKING)
   {
      // Transition back to normal — check TPs first
      CheckLegTPs(slotIndex);
      
      if(IsClusterComplete(slotIndex))
      {
         g_clusters[slotIndex].state = CLUSTER_CLOSED;
      }
      else
      {
         // Resume normal operation
         g_clusters[slotIndex].state = CLUSTER_NORMAL;
      }
   }
   else if(g_clusters[slotIndex].state == CLUSTER_LOCKED)
   {
      ManageHedgeLock(slotIndex);
   }
}

//+------------------------------------------------------------------+
//| Check if price has moved enough to open the next leg               |
//+------------------------------------------------------------------+
bool ShouldOpenNextLeg(int slotIndex)
{
   if(g_clusters[slotIndex].legsOpened >= MaxLegs)
      return false;
   
   if(g_clusters[slotIndex].state != CLUSTER_NORMAL && 
      g_clusters[slotIndex].state != CLUSTER_UNLOCKING)
      return false;
   
   double currentPrice;
   
   if(g_clusters[slotIndex].direction == DIR_LONG)
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double triggerPrice = g_clusters[slotIndex].lastLegPrice - g_clusters[slotIndex].gridStep;
      return (currentPrice <= triggerPrice);
   }
   else if(g_clusters[slotIndex].direction == DIR_SHORT)
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double triggerPrice = g_clusters[slotIndex].lastLegPrice + g_clusters[slotIndex].gridStep;
      return (currentPrice >= triggerPrice);
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Scan legs for TP fills                                             |
//+------------------------------------------------------------------+
void CheckLegTPs(int slotIndex)
{
   for(int leg = 1; leg <= g_clusters[slotIndex].legsOpened; leg++)
   {
      if(!g_clusters[slotIndex].legs[leg].isOpen)
         continue;
      
      ulong ticket = g_clusters[slotIndex].legs[leg].ticket;
      
      if(PositionSelectByTicket(ticket))
         continue; // Still open
      
      // Position is gone — closed by TP or other
      g_clusters[slotIndex].legs[leg].isOpen    = false;
      g_clusters[slotIndex].legs[leg].closeTime = TimeCurrent();
      g_clusters[slotIndex].legsClosed++;
      
      if(g_clusters[slotIndex].direction == DIR_LONG)
         g_clusters[slotIndex].totalLotsLong -= g_clusters[slotIndex].legs[leg].lotSize;
      else
         g_clusters[slotIndex].totalLotsShort -= g_clusters[slotIndex].legs[leg].lotSize;
      
      double closePL = GetDealProfitByTicket(ticket);
      g_clusters[slotIndex].legs[leg].closePL = closePL;
      
      Print("LEG CLOSED — Cluster:", g_clusters[slotIndex].clusterSeq,
            " Leg:", leg,
            " Ticket:", ticket,
            " P&L: $", DoubleToString(closePL, 2));
      
      LogToCSV("LEG_TP", g_clusters[slotIndex].clusterSeq, TIER_ID,
               (int)g_clusters[slotIndex].direction, 
               "Leg" + IntegerToString(leg),
               g_clusters[slotIndex].legs[leg].entryPrice, 
               g_clusters[slotIndex].legs[leg].lotSize,
               "ClosePL=" + DoubleToString(closePL, 2) + 
               " Remaining=" + IntegerToString(
                  g_clusters[slotIndex].legsOpened - g_clusters[slotIndex].legsClosed));
   }
}

//+------------------------------------------------------------------+
//| Look up realized P&L for a closed position from deal history       |
//+------------------------------------------------------------------+
double GetDealProfitByTicket(ulong positionTicket)
{
   // Select all history for this position
   if(!HistorySelectByPosition(positionTicket))
   {
      // Fallback: select recent history
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   }
   
   double totalProfit = 0;
   int totalDeals = HistoryDealsTotal();
   
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      
      // Match by position ID
      ulong dealPosition = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      
      if(dealPosition == positionTicket)
      {
         long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         
         // Only count exit deals (DEAL_ENTRY_OUT or DEAL_ENTRY_INOUT)
         if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_INOUT)
         {
            totalProfit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                        +  HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                        +  HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         }
      }
   }
   
   return totalProfit;
}

//+------------------------------------------------------------------+
//| Check if all legs in cluster are resolved                          |
//+------------------------------------------------------------------+
bool IsClusterComplete(int slotIndex)
{
   if(g_clusters[slotIndex].legsOpened <= 0)
      return false;
   
   if(g_clusters[slotIndex].legsClosed < g_clusters[slotIndex].legsOpened)
      return false;
   
   if(g_clusters[slotIndex].locksActive > 0)
      return false;
   
   for(int leg = 1; leg <= g_clusters[slotIndex].legsOpened; leg++)
   {
      if(g_clusters[slotIndex].legs[leg].isOpen)
         return false;
   }
   
   if(g_clusters[slotIndex].legs[0].isOpen)
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Close all positions in a cluster at market                         |
//+------------------------------------------------------------------+
void CloseCluster(int slotIndex, string reason)
{
   Print("CLOSING CLUSTER — Seq:", g_clusters[slotIndex].clusterSeq,
         " Reason: ", reason,
         " OpenLegs: ", g_clusters[slotIndex].legsOpened - g_clusters[slotIndex].legsClosed,
         " LocksActive: ", g_clusters[slotIndex].locksActive);
   
   // ── Close all grid legs ─────────────────────────────────────────
   for(int leg = 1; leg <= g_clusters[slotIndex].legsOpened; leg++)
   {
      if(!g_clusters[slotIndex].legs[leg].isOpen)
         continue;
      
      if(ClosePosition(g_clusters[slotIndex].legs[leg].ticket))
      {
         double closePL = GetDealProfitByTicket(g_clusters[slotIndex].legs[leg].ticket);
         g_clusters[slotIndex].legs[leg].isOpen    = false;
         g_clusters[slotIndex].legs[leg].closeTime = TimeCurrent();
         g_clusters[slotIndex].legs[leg].closePL   = closePL;
         g_clusters[slotIndex].legsClosed++;
         
         if(g_clusters[slotIndex].direction == DIR_LONG)
            g_clusters[slotIndex].totalLotsLong -= g_clusters[slotIndex].legs[leg].lotSize;
         else
            g_clusters[slotIndex].totalLotsShort -= g_clusters[slotIndex].legs[leg].lotSize;
      }
      else
      {
         Print("CRITICAL: Failed to close leg ", leg, " ticket ", 
               g_clusters[slotIndex].legs[leg].ticket, 
               " in cluster ", g_clusters[slotIndex].clusterSeq);
      }
   }
   
   // ── Close hedge leg if active ───────────────────────────────────
   if(g_clusters[slotIndex].legs[0].isOpen)
   {
      if(ClosePosition(g_clusters[slotIndex].legs[0].ticket))
      {
         g_clusters[slotIndex].legs[0].isOpen    = false;
         g_clusters[slotIndex].legs[0].closeTime = TimeCurrent();
         g_clusters[slotIndex].legs[0].closePL   = GetDealProfitByTicket(
                                                      g_clusters[slotIndex].legs[0].ticket);
         g_clusters[slotIndex].locksActive = 0;
      }
      else
      {
         Print("CRITICAL: Failed to close hedge leg ticket ",
               g_clusters[slotIndex].legs[0].ticket, 
               " in cluster ", g_clusters[slotIndex].clusterSeq);
      }
   }
   
   // ── Safety net: close any remaining positions by magic ──────────
   ClosePositionByMagic(g_clusters[slotIndex].magicBase);
   ClosePositionByMagic(g_clusters[slotIndex].hedgeMagic);
   
   // ── Calculate total cluster P&L ─────────────────────────────────
   double totalPL = 0;
   for(int leg = 0; leg <= g_clusters[slotIndex].legsOpened; leg++)
      totalPL += g_clusters[slotIndex].legs[leg].closePL;
   
   // ── Set state to closed ─────────────────────────────────────────
   g_clusters[slotIndex].state = CLUSTER_CLOSED;
   
   Print("CLUSTER CLOSED — Seq:", g_clusters[slotIndex].clusterSeq,
         " P&L: $", DoubleToString(totalPL, 2),
         " Reason: ", reason,
         " Duration: ", (int)(TimeCurrent() - g_clusters[slotIndex].openTime), " seconds");
   
   LogToCSV("CLUSTER_CLOSE", g_clusters[slotIndex].clusterSeq, TIER_ID,
            (int)g_clusters[slotIndex].direction, reason,
            SymbolInfoDouble(_Symbol, SYMBOL_BID), 0,
            "TotalPL=" + DoubleToString(totalPL, 2) +
            " Duration=" + IntegerToString(
               (int)(TimeCurrent() - g_clusters[slotIndex].openTime)) + "s" +
            " Legs=" + IntegerToString(g_clusters[slotIndex].legsOpened) +
            " Mode=" + EnumToString(g_clusters[slotIndex].mode));
}

//+------------------------------------------------------------------+
//| MODULE D: RISK MANAGEMENT (Gate 3 — stubs)                         |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Calculate base lot for a new cluster                               |
//|                                                                    |
//| Formula:                                                           |
//| BaseLot = (Equity × RiskPerCluster)                                |
//|         / (TotalWeightedLegs × MaxAdverseSteps × GridStep × ContractSize) |
//|                                                                    |
//| MaxAdverseSteps = 3 (hedge trigger at 2× + forced close at 1×)    |
//| ContractSize = 100 oz for XAUUSD                                   |
//+------------------------------------------------------------------+
double CalculateBaseLot(double gridStep)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxRiskUSD = equity * RiskPerCluster;
   
   double totalWeightedLegs = GetTotalWeightedLegs();
   double maxAdverseSteps = 3.0;
   
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contractSize <= 0)
   {
      Print("ERROR: Contract size is zero for ", _Symbol);
      return 0;
   }
   
   double divisor = totalWeightedLegs * maxAdverseSteps * gridStep * contractSize;
   
   if(divisor <= 0)
   {
      Print("ERROR: CalculateBaseLot divisor is zero or negative. ",
            "WeightedLegs=", totalWeightedLegs,
            " GridStep=", gridStep,
            " ContractSize=", contractSize);
      return 0;
   }
   
   double baseLot = maxRiskUSD / divisor;
   
   // Round down to volume step
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volumeMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volumeMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   if(volumeStep > 0)
      baseLot = MathFloor(baseLot / volumeStep) * volumeStep;
   
   // Check minimum
   if(baseLot < volumeMin)
   {
      static datetime lastBaseLotWarnBar = 0;
      datetime currentBar = iTime(_Symbol, PERIOD_M15, 0);
      if(currentBar != lastBaseLotWarnBar)
      {
         lastBaseLotWarnBar = currentBar;
         Print("WARNING: Calculated BaseLot (", DoubleToString(baseLot, 4),
               ") below minimum (", DoubleToString(volumeMin, 2),
               "). Insufficient equity for risk budget.",
               " Equity=$", DoubleToString(equity, 2),
               " GridStep=$", DoubleToString(gridStep, 2));
      }
      return 0;
   }
   
   // Cap at volume max (safety)
   if(baseLot > volumeMax)
      baseLot = volumeMax;
   
   // Sanity log
   double maxLoss = totalWeightedLegs * baseLot * maxAdverseSteps * gridStep * contractSize;
   Print("BaseLot: ", DoubleToString(baseLot, 2),
         " | MaxClusterLoss: $", DoubleToString(maxLoss, 2),
         " (", DoubleToString(maxLoss / equity * 100, 1), "% of equity)",
         " | Step: $", DoubleToString(gridStep, 2),
         " | WeightedLegs: ", DoubleToString(totalWeightedLegs, 1),
         " | ContractSize: ", DoubleToString(contractSize, 0));
   
   return baseLot;
}

//+------------------------------------------------------------------+
//| Calculate lot size for a specific leg number                       |
//|                                                                    |
//| Legs before LegScalingStart: baseLot                               |
//| Legs at or after LegScalingStart: baseLot × LegScalingFactor      |
//| Hard cap: never exceeds baseLot × MAX_LOT_MULTIPLIER (2.0)        |
//+------------------------------------------------------------------+
double GetLegLot(int legNumber, double baseLot)
{
   double lot = baseLot;
   
   if(legNumber >= LegScalingStart)
   {
      lot = baseLot * LegScalingFactor;
      
      // Hard cap at 2× base lot
      double maxLot = baseLot * MAX_LOT_MULTIPLIER;
      if(lot > maxLot)
         lot = maxLot;
   }
   
   // Round to volume step
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volumeMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   
   if(volumeStep > 0)
      lot = MathFloor(lot / volumeStep) * volumeStep;
   
   // Ensure minimum
   if(lot < volumeMin)
      lot = volumeMin;
   
   return lot;
}
//+------------------------------------------------------------------+
//| Calculate current portfolio heat (fraction of equity at risk)      |
//| Sums worst-case risk across all active clusters                    |
//+------------------------------------------------------------------+
double GetPortfolioHeat()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0) return 1.0; // Return max heat if equity is zero/negative
   
   double totalRisk = 0;
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   
   for(int i = 0; i < MAX_CLUSTERS_ABSOLUTE; i++)
   {
      if(g_clusters[i].state == CLUSTER_IDLE || g_clusters[i].state == CLUSTER_CLOSED)
         continue;
      
      // Calculate net lots still exposed
      double netLots = 0;
      for(int leg = 1; leg <= g_clusters[i].legsOpened; leg++)
      {
         if(g_clusters[i].legs[leg].isOpen)
            netLots += g_clusters[i].legs[leg].lotSize;
      }
      
      // Subtract hedge lots if locked
      if(g_clusters[i].state == CLUSTER_LOCKED && g_clusters[i].legs[0].isOpen)
         netLots -= g_clusters[i].legs[0].lotSize;  // Hedge reduces net exposure
      
      if(netLots < 0) netLots = 0; // Fully hedged or over-hedged
      
      // Worst case remaining risk
      double clusterRisk = netLots * 3.0 * g_clusters[i].gridStep * contractSize;
      totalRisk += clusterRisk;
   }
   
   return totalRisk / equity;
}

//+------------------------------------------------------------------+
//| Kill Switch — stops all trading if equity drops too far            |
//|                                                                    |
//| Triggers when equity < startEquity × (1 - KillSwitchPct)          |
//| Once triggered, it's permanent until manual reset (EA reload)      |
//+------------------------------------------------------------------+
void CheckKillSwitch()
{
   if(g_killSwitchActive)
      return; // Already triggered
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double threshold = g_startEquity * (1.0 - KillSwitchPct);
   
   if(equity < threshold)
   {
      g_killSwitchActive = true;
      
      Print("╔══════════════════════════════════════════════════════╗");
      Print("║            🛑 KILL SWITCH ACTIVATED 🛑              ║");
      Print("╠══════════════════════════════════════════════════════╣");
      Print("║ Equity: $", DoubleToString(equity, 2),
            "  Threshold: $", DoubleToString(threshold, 2));
      Print("║ Start Equity: $", DoubleToString(g_startEquity, 2),
            "  Loss: ", DoubleToString((1.0 - equity/g_startEquity) * 100, 1), "%");
      Print("║ ALL TRADING HALTED. Manual restart required.");
      Print("╚═══════════════════════════════════════���══════════════╝");
      
      // Close all active clusters immediately
      for(int i = 0; i < MAX_CLUSTERS_ABSOLUTE; i++)
      {
         if(g_clusters[i].state != CLUSTER_IDLE && g_clusters[i].state != CLUSTER_CLOSED)
            CloseCluster(i, "Kill switch activated");
      }
      
      LogToCSV("KILL_SWITCH", 0, TIER_ID,
               0, "KillSwitchActivated",
               SymbolInfoDouble(_Symbol, SYMBOL_BID), 0,
               "Equity=" + DoubleToString(equity, 2) +
               " Threshold=" + DoubleToString(threshold, 2) +
               " StartEquity=" + DoubleToString(g_startEquity, 2));
      
      // Save state so it persists across restarts
      SaveState();
   }
}

//+------------------------------------------------------------------+
//| Execute kill switch: close all, set cooldown                       |
//+------------------------------------------------------------------+
void ExecuteKillSwitch()
{
   // Gate 3:
   // 1. Set g_killSwitchActive = true
   // 2. Log KILL_SWITCH event
   // 3. CloseAllPositions()
   // 4. Set cooldown time (next session start)
   // 5. Send notification
}

//+------------------------------------------------------------------+
//| Check account protection mode                                      |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Protection Mode — reduces activity after peak drawdown             |
//|                                                                    |
//| Triggers when equity drops ProtectionDrawdownPct from peak equity  |
//| Effect: blocks new cluster opens, but existing clusters continue   |
//| Can be reset via input parameter or when equity recovers           |
//+------------------------------------------------------------------+
void CheckProtectionMode()
{
   if(g_killSwitchActive)
      return; // Kill switch overrides everything
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Track peak equity
   if(equity > g_peakEquity)
      g_peakEquity = equity;
   
   double drawdownFromPeak = (g_peakEquity - equity) / g_peakEquity;
   
   if(!g_protectionModeActive)
   {
      // Check if we should activate
      if(drawdownFromPeak >= ProtectionDrawdownPct)
      {
         g_protectionModeActive = true;
         
         Print("╔══════════════════════════════════════════════════════╗");
         Print("║          ⚠️ PROTECTION MODE ACTIVATED ⚠️            ║");
         Print("╠══════════════════════════════════════════════════════╣");
         Print("║ Equity: $", DoubleToString(equity, 2),
               "  Peak: $", DoubleToString(g_peakEquity, 2));
         Print("║ Drawdown: ", DoubleToString(drawdownFromPeak * 100, 1),
               "%  Threshold: ", DoubleToString(ProtectionDrawdownPct * 100, 1), "%");
         Print("║ New cluster opens BLOCKED. Existing clusters continue.");
         Print("╚══════════════════════════════════════════════════════╝");
         
         LogToCSV("PROTECTION_ON", 0, TIER_ID,
                  0, "ProtectionActivated",
                  SymbolInfoDouble(_Symbol, SYMBOL_BID), 0,
                  "Equity=" + DoubleToString(equity, 2) +
                  " Peak=" + DoubleToString(g_peakEquity, 2) +
                  " DD=" + DoubleToString(drawdownFromPeak * 100, 1) + "%");
         
         SaveState();
      }
   }
   else
   {
      // Check if we should deactivate
      // Reset if user set the input flag OR equity recovered past threshold
      if(ResetProtectionMode)
      {
         g_protectionModeActive = false;
         g_peakEquity = equity; // Reset peak to current
         
         Print("PROTECTION MODE RESET by user input. Peak equity reset to $",
               DoubleToString(equity, 2));
         
         LogToCSV("PROTECTION_OFF", 0, TIER_ID,
                  0, "ProtectionReset",
                  SymbolInfoDouble(_Symbol, SYMBOL_BID), 0,
                  "ResetByUser=true NewPeak=" + DoubleToString(equity, 2));
         
         SaveState();
      }
      else if(drawdownFromPeak < ProtectionDrawdownPct * 0.5)
      {
         // Auto-reset when drawdown recovers to half the threshold
         g_protectionModeActive = false;
         
         Print("PROTECTION MODE AUTO-RESET. Drawdown recovered to ",
               DoubleToString(drawdownFromPeak * 100, 1), "%");
         
         LogToCSV("PROTECTION_OFF", 0, TIER_ID,
                  0, "ProtectionAutoReset",
                  SymbolInfoDouble(_Symbol, SYMBOL_BID), 0,
                  "DD=" + DoubleToString(drawdownFromPeak * 100, 1) + "%");
         
         SaveState();
      }
   }
}

//+------------------------------------------------------------------+
//| Execute account protection lockout                                 |
//+------------------------------------------------------------------+
void ExecuteProtectionMode()
{
   // Gate 3:
   // 1. Set g_protectionModeActive = true
   // 2. CloseAllPositions()
   // 3. Persist to GlobalVariable
   // 4. Send alert + notification + email
   // 5. Log PROTECTION_MODE event
}

//+------------------------------------------------------------------+
//| Check if a cluster needs a hedge lock placed                       |
//|                                                                    |
//| Trigger: price has moved HedgeLockTriggerMultiplier × gridStep     |
//| beyond the last leg's entry, AND all legs are open (max reached)   |
//+------------------------------------------------------------------+
void CheckHedgeLock(int slotIndex)
{
   // ── Skip if hedge lock disabled ─────────────────────────────────
   if(!HedgeLockEnabled)
      return;
   
   // ── Skip if already locked ──────────────────────────────────────
   if(g_clusters[slotIndex].state == CLUSTER_LOCKED)
      return;
   
   // ── Skip if not at max legs ─────────────────────────────────────
   if(g_clusters[slotIndex].legsOpened < MaxLegs)
      return;
   
   // ── Skip if already used max locks ──────────────────────────────
   if(g_clusters[slotIndex].locksActive >= MaxLocksPerCluster)
      return;
   
   // ── Calculate trigger distance ──────────────────────────────────
   double triggerDistance = g_clusters[slotIndex].gridStep * HedgeLockTriggerMultiplier;
   double lastLegPrice   = g_clusters[slotIndex].lastLegPrice;
   double currentPrice;
   
   if(g_clusters[slotIndex].direction == DIR_LONG)
   {
      // Long cluster: adverse = price dropping below last leg
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(currentPrice > lastLegPrice - triggerDistance)
         return; // Not deep enough
   }
   else if(g_clusters[slotIndex].direction == DIR_SHORT)
   {
      // Short cluster: adverse = price rising above last leg
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(currentPrice < lastLegPrice + triggerDistance)
         return; // Not deep enough
   }
   else
      return;
   
   // ── Calculate hedge lot (net open lots) ─────────────────────────
   double hedgeLot = 0;
   for(int leg = 1; leg <= g_clusters[slotIndex].legsOpened; leg++)
   {
      if(g_clusters[slotIndex].legs[leg].isOpen)
         hedgeLot += g_clusters[slotIndex].legs[leg].lotSize;
   }
   
   if(hedgeLot <= 0)
      return;
   
   // Round to volume step
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volumeMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(volumeStep > 0)
      hedgeLot = MathFloor(hedgeLot / volumeStep) * volumeStep;
   if(hedgeLot < volumeMin)
      hedgeLot = volumeMin;
   
   // ── Place hedge order (opposite direction) ──────────────────────
   ENUM_ORDER_TYPE hedgeType;
   if(g_clusters[slotIndex].direction == DIR_LONG)
      hedgeType = ORDER_TYPE_SELL;
   else
      hedgeType = ORDER_TYPE_BUY;
   
   string comment = "Hedge_C" + IntegerToString(g_clusters[slotIndex].clusterSeq);
   
   ulong ticket = 0;
   if(!SendMarketOrder(_Symbol, hedgeType, hedgeLot, 
                       g_clusters[slotIndex].hedgeMagic, comment, 0, ticket))
   {
      Print("ERROR: Failed to place hedge for cluster ", g_clusters[slotIndex].clusterSeq);
      return;
   }
   
   // ── Get fill price ──────────────────────────────────────────────
   double fillPrice = currentPrice;
   if(PositionSelectByTicket(ticket))
      fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   
   // ── Update cluster state ────────────────────────────────────────
   g_clusters[slotIndex].state       = CLUSTER_LOCKED;
   g_clusters[slotIndex].locksActive = 1;
   g_clusters[slotIndex].lockPrice   = fillPrice;
   g_clusters[slotIndex].lockTime    = TimeCurrent();
   
   // Track in hedge leg slot (index 0)
   g_clusters[slotIndex].legs[0].ticket     = ticket;
   g_clusters[slotIndex].legs[0].legNumber  = 0;
   g_clusters[slotIndex].legs[0].entryPrice = fillPrice;
   g_clusters[slotIndex].legs[0].lotSize    = hedgeLot;
   g_clusters[slotIndex].legs[0].tpPrice    = 0; // No TP on hedge
   g_clusters[slotIndex].legs[0].isOpen     = true;
   g_clusters[slotIndex].legs[0].isHedge    = true;
   g_clusters[slotIndex].legs[0].openTime   = TimeCurrent();
   
   if(g_clusters[slotIndex].direction == DIR_LONG)
      g_clusters[slotIndex].totalLotsShort += hedgeLot;
   else
      g_clusters[slotIndex].totalLotsLong += hedgeLot;
   
   Print("HEDGE LOCKED — Cluster:", g_clusters[slotIndex].clusterSeq,
         " HedgeLot:", DoubleToString(hedgeLot, 2),
         " @$", DoubleToString(fillPrice, 2),
         " TriggerDist:$", DoubleToString(triggerDistance, 2),
         " LastLeg:$", DoubleToString(lastLegPrice, 2));
   
   LogToCSV("HEDGE_LOCK", g_clusters[slotIndex].clusterSeq, TIER_ID,
            (int)g_clusters[slotIndex].direction, "HedgeLocked",
            fillPrice, hedgeLot,
            "TriggerDist=" + DoubleToString(triggerDistance, 2) +
            " LastLeg=" + DoubleToString(lastLegPrice, 2));
}

//+------------------------------------------------------------------+
//| Execute hedge lock: open counter-position                          |
//+------------------------------------------------------------------+
void ExecuteHedgeLock(int slotIndex)
{
   // Gate 3:
   // 1. Calculate hedge lot = net cluster exposure
   // 2. Determine hedge direction (opposite of net)
   // 3. Send market order with hedgeMagic
   // 4. Record lockPrice, set state to CLUSTER_LOCKED
   // 5. Log HEDGE_LOCK event
}

//+------------------------------------------------------------------+
//| Manage an active hedge lock                                        |
//|                                                                    |
//| Two outcomes:                                                      |
//| 1. UNLOCK: Price reverses back within unlock distance → remove     |
//|    hedge and let grid legs try to hit TP again                     |
//| 2. FORCE CLOSE: Price moves further against → close everything     |
//+------------------------------------------------------------------+
void ManageHedgeLock(int slotIndex)
{
   if(g_clusters[slotIndex].state != CLUSTER_LOCKED)
      return;
   
   if(!g_clusters[slotIndex].legs[0].isOpen)
   {
      // Hedge was closed externally — force close the cluster
      Print("WARNING: Hedge position disappeared for cluster ", 
            g_clusters[slotIndex].clusterSeq, " — force closing");
      CloseCluster(slotIndex, "Hedge disappeared");
      return;
   }
   
   double lockPrice    = g_clusters[slotIndex].lockPrice;
   double gridStep     = g_clusters[slotIndex].gridStep;
   double unlockDist   = gridStep * HedgeUnlockMultiplier;
   double forceCloseDist = gridStep * HedgeForceCloseMultiplier;
   double currentPrice;
   
   if(g_clusters[slotIndex].direction == DIR_LONG)
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      
      // ── Check unlock: price recovered above lock price ───────────
      if(currentPrice >= lockPrice + unlockDist)
      {
         UnlockHedge(slotIndex);
         return;
      }
      
      // ── Check force close: price dropped further ─────────────────
      if(currentPrice <= lockPrice - forceCloseDist)
      {
         CloseCluster(slotIndex, "Hedge force close — adverse beyond threshold");
         return;
      }
   }
   else if(g_clusters[slotIndex].direction == DIR_SHORT)
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      // ── Check unlock: price dropped back below lock price ────────
      if(currentPrice <= lockPrice - unlockDist)
      {
         UnlockHedge(slotIndex);
         return;
      }
      
      // ── Check force close: price rose further ────────────────────
      if(currentPrice >= lockPrice + forceCloseDist)
      {
         CloseCluster(slotIndex, "Hedge force close — adverse beyond threshold");
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Remove hedge and return cluster to normal state                    |
//+------------------------------------------------------------------+
void UnlockHedge(int slotIndex)
{
   if(!g_clusters[slotIndex].legs[0].isOpen)
      return;
   
   ulong hedgeTicket = g_clusters[slotIndex].legs[0].ticket;
   
   if(ClosePosition(hedgeTicket))
   {
      double closePL = GetDealProfitByTicket(hedgeTicket);
      
      g_clusters[slotIndex].legs[0].isOpen    = false;
      g_clusters[slotIndex].legs[0].closeTime = TimeCurrent();
      g_clusters[slotIndex].legs[0].closePL   = closePL;
      g_clusters[slotIndex].locksActive        = 0;
      g_clusters[slotIndex].state              = CLUSTER_UNLOCKING;
      
      if(g_clusters[slotIndex].direction == DIR_LONG)
         g_clusters[slotIndex].totalLotsShort -= g_clusters[slotIndex].legs[0].lotSize;
      else
         g_clusters[slotIndex].totalLotsLong -= g_clusters[slotIndex].legs[0].lotSize;
      
      Print("HEDGE UNLOCKED — Cluster:", g_clusters[slotIndex].clusterSeq,
            " HedgePL:$", DoubleToString(closePL, 2),
            " Returning to normal operation");
      
      LogToCSV("HEDGE_UNLOCK", g_clusters[slotIndex].clusterSeq, TIER_ID,
               (int)g_clusters[slotIndex].direction, "HedgeUnlocked",
               SymbolInfoDouble(_Symbol, SYMBOL_BID), 
               g_clusters[slotIndex].legs[0].lotSize,
               "HedgePL=" + DoubleToString(closePL, 2));
      
      // After one tick in UNLOCKING, ManageCluster will move it to NORMAL
      // (CheckLegTPs and ShouldOpenNextLeg already handle UNLOCKING state)
   }
   else
   {
      Print("ERROR: Failed to close hedge for cluster ", g_clusters[slotIndex].clusterSeq);
   }
}

//+------------------------------------------------------------------+
//| Force close: close entire cluster + hedge                          |
//+------------------------------------------------------------------+
void ExecuteHedgeForceClose(int slotIndex)
{
   // Gate 3:
   // 1. Close all positions (cluster + hedge)
   // 2. Set state to CLUSTER_CLOSED
   // 3. Log HEDGE_FORCED_CLOSE event
}

//+------------------------------------------------------------------+
//| Check session time exit                                            |
//+------------------------------------------------------------------+
void CheckSessionTimeExit()
{
   // Gate 3:
   // If past SessionCloseHour:Minute → close all open clusters
}

//+------------------------------------------------------------------+
//| Check if past session close time                                   |
//+------------------------------------------------------------------+
bool IsPastSessionClose()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   
   // Skip weekends
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return true; // Treat weekends as "past close"
   
   int currentSeconds = dt.hour * 3600 + dt.min * 60 + dt.sec;
   
   return (currentSeconds >= g_sessionCloseSeconds);
}

//+------------------------------------------------------------------+
//| Check if current time is Friday close window                       |
//+------------------------------------------------------------------+
bool IsFridayCloseTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   
   if(dt.day_of_week != 5)
      return false;
   
   int currentSeconds = dt.hour * 3600 + dt.min * 60 + dt.sec;
   
   return (currentSeconds >= g_fridayCloseSeconds);
}

//+------------------------------------------------------------------+
//| Check if Monday unwind time                                        |
//+------------------------------------------------------------------+
bool IsMondayUnwindTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   
   if(dt.day_of_week != 1)
      return false;
   
   // Unwind after market open + delay
   int currentSeconds = dt.hour * 3600 + dt.min * 60 + dt.sec;
   int unwindSeconds = g_sessionStartSeconds + MONDAY_UNWIND_DELAY_MIN * 60;
   
   return (currentSeconds >= unwindSeconds);
}

//+------------------------------------------------------------------+
//| Execute weekend safety routine                                     |
//+------------------------------------------------------------------+
void ExecuteWeekendSafety()
{
   // Gate 3:
   // Scan all clusters
   // Intraday: close all
   // Log actions
   // Verify no unhedged exposure remains
}

//+------------------------------------------------------------------+
//| Execute Monday morning hedge unwind                                |
//+------------------------------------------------------------------+
void ExecuteMondayUnwind()
{
   // Gate 3:
   // Close weekend hedges
   // Restore cluster states
}

//+------------------------------------------------------------------+
//| Check if current spread is viable for new clusters                 |
//+------------------------------------------------------------------+
bool CheckSpreadViability()
{
   // Gate 3:
   // double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   // return (spread / g_currentGridStep) <= SPREAD_TO_STEP_MAX_RATIO;
   return true; // Stub: allow until Gate 3
}

//+------------------------------------------------------------------+
//| Check if sufficient margin for new position                        |
//+------------------------------------------------------------------+
bool CheckMarginSufficiency(double lots)
{
   // Gate 3:
   // double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   // double requiredMargin = lots × margin requirement per lot
   // return (requiredMargin < freeMargin × MARGIN_SAFETY_FACTOR)
   return true; // Stub: allow until Gate 3
}

//+------------------------------------------------------------------+
//| MODULE E: NEWS FILTER (Gate 3 — stubs)                             |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Check if currently within news buffer window                       |
//+------------------------------------------------------------------+
bool IsNewsWindow()
{
   // Gate 3:
   // If !NewsFilterEnabled → return false
   // If time since last check < NEWS_CHECK_INTERVAL_SEC → return cached g_isNewsWindow
   // Call UpdateNewsCache()
   // Return g_isNewsWindow
   return false;
}

//+------------------------------------------------------------------+
//| Refresh cached news events from economic calendar                  |
//+------------------------------------------------------------------+
void UpdateNewsCache()
{
   // Gate 3:
   // Use CalendarValueHistory() to get events within ±NewsBufferMinutes
   // Filter by NewsFilterCurrencies and NewsMinImportance
   // Set g_isNewsWindow = true if any qualifying event found
   // Set g_lastNewsCheck = TimeCurrent()
}

//+------------------------------------------------------------------+
//| MODULE F: ORDER EXECUTION (Gate 2 basic, Gate 3 hardened)          |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Send a market order with TP                                        |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Send a market order with TP                                        |
//+------------------------------------------------------------------+
bool SendMarketOrder(string symbol, ENUM_ORDER_TYPE type, double lots,
                     int magic, string comment, double tp, ulong &ticket)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = symbol;
   request.volume    = lots;
   request.type      = type;
   request.magic     = magic;
   request.comment   = comment;
   request.deviation = 30;
   
   // ── Set filling mode ────────────────────────────────────────────
   // Try broker-reported mode first, fall back to FOK
   long fillMode = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   
   if((fillMode & SYMBOL_FILLING_FOK) != 0)
      request.type_filling = ORDER_FILLING_FOK;
   else if((fillMode & SYMBOL_FILLING_IOC) != 0)
      request.type_filling = ORDER_FILLING_IOC;
   else
      request.type_filling = ORDER_FILLING_RETURN;  // Default RETURN when neither FOK nor IOC reported
   
   // ── Set TP (normalize to tick size) ─────────────────────────────
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0 && tp > 0)
      request.tp = MathRound(tp / tickSize) * tickSize;
   else
      request.tp = tp;
   
   // ── Set price ───────────────────────────────────────────────────
   if(type == ORDER_TYPE_BUY)
      request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
   else
      request.price = SymbolInfoDouble(symbol, SYMBOL_BID);
   
   // ── Send with retry ─────────────────────────────────────────────
   for(int attempt = 1; attempt <= ORDERSEND_MAX_RETRIES; attempt++)
   {
      // Refresh price on retry
      if(attempt > 1)
      {
         if(type == ORDER_TYPE_BUY)
            request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
         else
            request.price = SymbolInfoDouble(symbol, SYMBOL_BID);
         Sleep(ORDERSEND_RETRY_DELAY_MS);
      }
      
      ResetLastError();
      bool sent = OrderSend(request, result);
      
      if(sent && (result.retcode == TRADE_RETCODE_DONE || 
                  result.retcode == TRADE_RETCODE_DONE_PARTIAL))
      {
         ticket = result.deal;
         if(ticket == 0)
            ticket = result.order;
         return true;
      }
      
      // If fill mode rejected, cycle through all three modes: FOK → IOC → RETURN → FOK
      if(result.retcode == 10030) // Unsupported filling mode
      {
         if(request.type_filling == ORDER_FILLING_FOK)
            request.type_filling = ORDER_FILLING_IOC;
         else if(request.type_filling == ORDER_FILLING_IOC)
            request.type_filling = ORDER_FILLING_RETURN;
         else
            request.type_filling = ORDER_FILLING_FOK;
         
         Print("RETRY: Switching fill mode to ", EnumToString(request.type_filling),
               " (attempt ", attempt, "/", ORDERSEND_MAX_RETRIES, ")");
         continue;
      }
      
      Print("ERROR: OrderSend attempt ", attempt, "/", ORDERSEND_MAX_RETRIES,
            ". ", symbol, " ", EnumToString(type),
            " ", lots, " lots. Error:", GetLastError(),
            " RetCode:", result.retcode,
            " Comment:", result.comment);
   }
   
   ticket = 0;
   return false;
}

//+------------------------------------------------------------------+
//| Close a specific position by ticket                                |
//+------------------------------------------------------------------+
bool ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return true; // Already closed
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action    = TRADE_ACTION_DEAL;
   request.position  = ticket;
   request.symbol    = PositionGetString(POSITION_SYMBOL);
   request.volume    = PositionGetDouble(POSITION_VOLUME);
   request.deviation = 30;
   
   // ── Set filling mode ────────────────────────────────────────────
   long fillMode = SymbolInfoInteger(request.symbol, SYMBOL_FILLING_MODE);
   
   if((fillMode & SYMBOL_FILLING_FOK) != 0)
      request.type_filling = ORDER_FILLING_FOK;
   else if((fillMode & SYMBOL_FILLING_IOC) != 0)
      request.type_filling = ORDER_FILLING_IOC;
   else
      request.type_filling = ORDER_FILLING_RETURN;  // Default RETURN when neither FOK nor IOC reported
   
   long posType = PositionGetInteger(POSITION_TYPE);
   if(posType == POSITION_TYPE_BUY)
   {
      request.type  = ORDER_TYPE_SELL;
      request.price = SymbolInfoDouble(request.symbol, SYMBOL_BID);
   }
   else
   {
      request.type  = ORDER_TYPE_BUY;
      request.price = SymbolInfoDouble(request.symbol, SYMBOL_ASK);
   }
   
   for(int attempt = 1; attempt <= ORDERSEND_MAX_RETRIES; attempt++)
   {
      if(attempt > 1)
      {
         if(posType == POSITION_TYPE_BUY)
            request.price = SymbolInfoDouble(request.symbol, SYMBOL_BID);
         else
            request.price = SymbolInfoDouble(request.symbol, SYMBOL_ASK);
         Sleep(ORDERSEND_RETRY_DELAY_MS);
      }
      
      ResetLastError();
      bool sent = OrderSend(request, result);
      
      if(sent && (result.retcode == TRADE_RETCODE_DONE || 
                  result.retcode == TRADE_RETCODE_DONE_PARTIAL))
         return true;
      
      if(result.retcode == 10030)
      {
         if(request.type_filling == ORDER_FILLING_FOK)
            request.type_filling = ORDER_FILLING_IOC;
         else if(request.type_filling == ORDER_FILLING_IOC)
            request.type_filling = ORDER_FILLING_RETURN;
         else
            request.type_filling = ORDER_FILLING_FOK;
         continue;
      }
      
      Print("ERROR: ClosePosition attempt ", attempt, "/", ORDERSEND_MAX_RETRIES,
            ". Ticket:", ticket,
            " Error:", GetLastError(),
            " RetCode:", result.retcode);
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Close all positions matching a specific magic number               |
//+------------------------------------------------------------------+
bool ClosePositionByMagic(int magic)
{
   bool allClosed = true;
   
   // Iterate in reverse (closing changes position indices)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      
      if(PositionGetInteger(POSITION_MAGIC) == magic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         if(!ClosePosition(ticket))
            allClosed = false;
      }
   }
   
   return allClosed;
}


//+------------------------------------------------------------------+
//| MODULE G: LOGGING & ALERTS (Gate 3 — functional for Gate 1)        |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Write event to daily CSV journal                                   |
//+------------------------------------------------------------------+
void LogToCSV(string eventType, int clusterID, int tierID,
              int direction, string action, double price,
              double lots, string details = "")
{
   if(!EnableCSVLogging) return;
   
   string dateStr = TimeToString(TimeCurrent(), TIME_DATE);
   StringReplace(dateStr, ".", "");
   string filename = LogFilePath + "_" + dateStr + ".csv";
   
   int handle = FileOpen(filename, FILE_READ|FILE_WRITE|FILE_CSV, ',');
   if(handle == INVALID_HANDLE)
   {
      Print("ERROR: Cannot open log file: ", filename, " Error: ", GetLastError());
      return;
   }
   
   // Write header if new file
   if(FileSize(handle) == 0)
   {
      FileWrite(handle, 
         "Timestamp", "EventType", "ClusterID", "TierID",
         "Direction", "Action", "Price", "Lots", "FloatingPL",
         "Equity", "Balance", "Details");
   }
   
   // Seek to end
   FileSeek(handle, 0, SEEK_END);
   
   FileWrite(handle,
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      eventType,
      IntegerToString(clusterID),
      IntegerToString(tierID),
      IntegerToString(direction),
      action,
      DoubleToString(price, 2),
      DoubleToString(lots, 2),
      DoubleToString(AccountInfoDouble(ACCOUNT_PROFIT), 2),
      DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
      DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
      details);
   
   FileClose(handle);
}

//+------------------------------------------------------------------+
//| Send notification to user (push + optional email) — continued      |
//+------------------------------------------------------------------+
void NotifyUser(string message, bool isCritical)
{
   if(EnablePushNotifications)
   {
      if(!SendNotification("GridEA [" + IntegerToString(MagicBase) + "]: " + message))
         Print("WARNING: Push notification failed. Message: ", message);
   }
   
   if(isCritical && EnableEmailAlerts)
   {
      string subject = "GridEA CRITICAL [" + IntegerToString(MagicBase) + "]";
      if(!SendMail(subject, message))
         Print("WARNING: Email alert failed. Message: ", message);
   }
   
   // Always print to terminal regardless of notification settings
   if(isCritical)
      Alert("GridEA: ", message);
}

//+------------------------------------------------------------------+
//| MODULE H: STATE PERSISTENCE (Gate 7 — functional stubs for Gate 1) |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Save critical state to global variables (survives EA restart)      |
//+------------------------------------------------------------------+
void SaveState()
{
   string prefix = "GridEA_" + IntegerToString(MagicBase) + "_";
   
   GlobalVariableSet(prefix + "StartEquity",     g_startEquity);
   GlobalVariableSet(prefix + "PeakEquity",      g_peakEquity);
   GlobalVariableSet(prefix + "KillSwitch",      g_killSwitchActive ? 1.0 : 0.0);
   GlobalVariableSet(prefix + "ProtectionMode",  g_protectionModeActive ? 1.0 : 0.0);
   GlobalVariableSet(prefix + "NextClusterSeq",  (double)g_nextClusterSeq);
}

//+------------------------------------------------------------------+
//| Load state from global variables                                   |
//+------------------------------------------------------------------+
void LoadState()
{
   string prefix = "GridEA_" + IntegerToString(MagicBase) + "_";
   
   if(GlobalVariableCheck(prefix + "StartEquity"))
      g_startEquity = GlobalVariableGet(prefix + "StartEquity");
   
   if(GlobalVariableCheck(prefix + "PeakEquity"))
      g_peakEquity = GlobalVariableGet(prefix + "PeakEquity");
   
   if(GlobalVariableCheck(prefix + "KillSwitch"))
      g_killSwitchActive = (GlobalVariableGet(prefix + "KillSwitch") > 0.5);
   
   if(GlobalVariableCheck(prefix + "ProtectionMode"))
      g_protectionModeActive = (GlobalVariableGet(prefix + "ProtectionMode") > 0.5);
   
   if(GlobalVariableCheck(prefix + "NextClusterSeq"))
      g_nextClusterSeq = (int)GlobalVariableGet(prefix + "NextClusterSeq");
   
   Print("State loaded — StartEquity: $", DoubleToString(g_startEquity, 2),
         " PeakEquity: $", DoubleToString(g_peakEquity, 2),
         " Protection: ", g_protectionModeActive,
         " KillSwitch: ", g_killSwitchActive,
         " NextSeq: ", g_nextClusterSeq);
}

//+------------------------------------------------------------------+
//| Reconstruct cluster state from open positions after EA restart     |
//+------------------------------------------------------------------+
void ReconstructClustersFromPositions()
{
   // Gate 7: Full reconstruction logic
   // For Gate 1: count positions in our magic range and warn if found
   
   int magicMin = MagicBase;
   int magicMax = MagicBase + 99999;
   int foundPositions = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      
      if(posMagic >= magicMin && posMagic <= magicMax &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         foundPositions++;
         
         // Extract cluster info from magic number
         int localMagic = (int)(posMagic - MagicBase);
         int directionID = localMagic / 1000;
         int clusterSeq  = localMagic % 1000;
         
         Print("Found existing position — Ticket: ", ticket,
               " Magic: ", posMagic,
               " Direction: ", directionID,
               " ClusterSeq: ", clusterSeq,
               " Lots: ", PositionGetDouble(POSITION_VOLUME),
               " Profit: ", DoubleToString(PositionGetDouble(POSITION_PROFIT), 2));
      }
   }
   
   if(foundPositions > 0)
   {
      Print("WARNING: Found ", foundPositions, " existing positions in EA magic range.");
      Print("Gate 7 will implement full state reconstruction.");
      Print("Current behavior: positions exist but are NOT tracked by cluster engine.");
      Print("Risk management (kill switch, protection mode) still monitors them via ACCOUNT_PROFIT.");
      
      LogToCSV("RESTART_WARN", 0, TIER_ID, 0, "Untracked positions found",
               0, 0, "Count=" + IntegerToString(foundPositions));
   }
   else
   {
      Print("No existing positions found in EA magic range. Clean start.");
   }
}

//+------------------------------------------------------------------+
//| UTILITY FUNCTIONS                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Check for new bar on a specific timeframe                          |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES timeframe)
{
   datetime currentBarTime = iTime(_Symbol, timeframe, 0);
   
   if(timeframe == PERIOD_M15)
   {
      if(currentBarTime != g_lastBarTimeM15)
      {
         g_lastBarTimeM15 = currentBarTime;
         return true;
      }
   }
   else if(timeframe == ATRTimeframe)
   {
      if(currentBarTime != g_lastBarTimeATR)
      {
         g_lastBarTimeATR = currentBarTime;
         return true;
      }
   }
   else if(timeframe == ADXTimeframe)
   {
      if(currentBarTime != g_lastBarTimeADX)
      {
         g_lastBarTimeADX = currentBarTime;
         return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check if current time is within trading session                    |
//+------------------------------------------------------------------+
bool IsInSession()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   
   // Skip weekends
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;
   
   int currentSeconds = dt.hour * 3600 + dt.min * 60 + dt.sec;
   
   return (currentSeconds >= g_sessionStartSeconds && 
           currentSeconds < g_sessionCloseSeconds);
}

//+------------------------------------------------------------------+
//| Check if before new cluster cutoff time                            |
//+------------------------------------------------------------------+
bool IsBeforeCutoff()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   
   int currentSeconds = dt.hour * 3600 + dt.min * 60 + dt.sec;
   
   return (currentSeconds < g_newClusterCutoffSeconds);
}

//+------------------------------------------------------------------+
//| Check if ATR exceeds suspension threshold                          |
//+------------------------------------------------------------------+
bool IsSuspended()
{
   double midPrice = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2.0;
   if(midPrice <= 0) return false;
   double atrPct = (g_currentATR / midPrice) * 100.0;
   return (atrPct > SuspendATRPctThreshold);
}

//+------------------------------------------------------------------+
//| Calculate total weighted legs for lot sizing formula                |
//|                                                                    |
//| Legs before LegScalingStart: weight 1.0 each                      |
//| Legs at or after LegScalingStart: weight LegScalingFactor each     |
//+------------------------------------------------------------------+
double GetTotalWeightedLegs()
{
   double total = 0;
   
   for(int i = 1; i <= MaxLegs; i++)
   {
      if(i < LegScalingStart)
         total += 1.0;
      else
         total += LegScalingFactor;
   }
   
   return total;
}

//+------------------------------------------------------------------+
//| Count currently active (non-IDLE) clusters                         |
//+------------------------------------------------------------------+
int GetActiveClusterCount()
{
   int count = 0;
   for(int i = 0; i < MAX_CLUSTERS_ABSOLUTE; i++)
   {
      if(g_clusters[i].state != CLUSTER_IDLE && 
         g_clusters[i].state != CLUSTER_CLOSED)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Close all open clusters with a reason                              |
//+------------------------------------------------------------------+
void CloseAllOpenClusters(string reason)
{
   for(int i = 0; i < MAX_CLUSTERS_ABSOLUTE; i++)
   {
      if(g_clusters[i].state != CLUSTER_IDLE && 
         g_clusters[i].state != CLUSTER_CLOSED)
      {
         CloseCluster(i, reason);
      }
   }
}

//+------------------------------------------------------------------+
//| Get next available cluster sequence number                         |
//+------------------------------------------------------------------+
int GetNextClusterSeq()
{
   int seq = g_nextClusterSeq;
   g_nextClusterSeq++;
   
   if(g_nextClusterSeq > 999)
      g_nextClusterSeq = 1; // Wrap around
   
   GlobalVariableSet(GetGlobalVarName("NextClusterSeq"), (double)g_nextClusterSeq);
   
   return seq;
}

//+------------------------------------------------------------------+
//| Build magic number for a cluster                                   |
//+------------------------------------------------------------------+
int BuildMagicNumber(ENUM_CLUSTER_DIRECTION direction, int clusterSeq)
{
   // MAGIC = BASE(120000) + DirectionID(×1000) + ClusterSeq
   // TierID is already embedded in MagicBase (120000 → Tier 2)
   return MagicBase + (int)direction * 1000 + clusterSeq;
}

//+------------------------------------------------------------------+
//| Build hedge magic number from cluster magic                        |
//+------------------------------------------------------------------+
int BuildHedgeMagic(int clusterMagicBase)
{
   // Replace direction component with hedge direction (3)
   // Original: MagicBase + direction*1000 + seq
   // Hedge:    MagicBase + 3*1000 + seq
   int seq = clusterMagicBase % 1000;
   return MagicBase + HEDGE_MAGIC_OFFSET + seq;
}

//+------------------------------------------------------------------+
//| Get current broker time adjusted for GMT offset                    |
//+------------------------------------------------------------------+
datetime GetBrokerAdjustedTime()
{
   return TimeCurrent(); // Broker server time is already in broker timezone
}

//+------------------------------------------------------------------+
//| Calculate seconds since midnight for current broker time           |
//+------------------------------------------------------------------+
int GetBrokerSecondsSinceMidnight()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   return dt.hour * 3600 + dt.min * 60 + dt.sec;
}

//+------------------------------------------------------------------+
//| MAIN EVENT HANDLER                                                 |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Expert tick function — Master Control Loop                         |
//+------------------------------------------------------------------+
void OnTick()
{

   // ══ RISK CHECKS (run every tick, before anything else) ══════════
   CheckKillSwitch();
   if(g_killSwitchActive)
      return; // Nothing else runs
   
   CheckProtectionMode();
   // ════════════════════════════════════════════════════════════════
   // PRIORITY 2: Kill Switch
   // ════════════════════════════════════════════════════════════════
   if(g_killSwitchActive)
   {
      // Check if cooldown has expired
      if(TimeCurrent() >= g_killSwitchCooldownUntil && g_killSwitchCooldownUntil > 0)
      {
         g_killSwitchActive = false;
         GlobalVariableSet(GetGlobalVarName("KillSwitchActive"), 0.0);
         LogToCSV("KILL_SWITCH_RESET", 0, TIER_ID, 0, "Cooldown expired",
                  0, 0, "");
      }
      else
         return; // Still in cooldown
   }
   
   CheckKillSwitch(); // May close all and set cooldown
   if(g_killSwitchActive)
      return;
   
   // ════════════════════════════════════════════════════════════════
   // PRIORITY 3: Weekend Safety
   // ════════════════════════════════════════════════════════════════
   if(IsFridayCloseTime() && !g_weekendSafetyExecuted)
   {
      ExecuteWeekendSafety();
      g_weekendSafetyExecuted = true;
      return; // No further action on Friday after close
   }
   
   // Reset weekend flag on non-Friday
   MqlDateTime dtWeekCheck;
   TimeCurrent(dtWeekCheck);
   if(dtWeekCheck.day_of_week != 5)
      g_weekendSafetyExecuted = false;
   
   // Monday unwind
   if(IsMondayUnwindTime() && !g_mondayUnwindExecuted)
   {
      ExecuteMondayUnwind();
      g_mondayUnwindExecuted = true;
   }
   
   // Reset Monday flag on non-Monday
   if(dtWeekCheck.day_of_week != 1)
      g_mondayUnwindExecuted = false;
   
   // ════════════════════════════════════════════════════════════════
   // PRIORITY 4: Session Time Exit
   // ════════════════════════════════════════════════════════════════
   if(IsPastSessionClose())
   {
      if(GetActiveClusterCount() > 0)
      {
         CloseAllOpenClusters("Session time exit");
         LogToCSV("SESSION_CLOSE", 0, TIER_ID, 0, "All clusters closed",
                  0, 0, "Session time exit triggered");
      }
      return; // Outside session — no further action
   }
   
   // ════════════════════════════════════════════════════════════════
   // PRIORITY 5: Manage Existing Clusters
   // ════════════════════════════════════════════════════════════════
   for(int i = 0; i < MAX_CLUSTERS_ABSOLUTE; i++)
   {
      if(g_clusters[i].state == CLUSTER_IDLE)
         continue;
      
      if(g_clusters[i].state == CLUSTER_CLOSED)
      {
         // Free the slot
         LogToCSV("CLUSTER_CLOSE", g_clusters[i].clusterSeq, TIER_ID,
                  (int)g_clusters[i].direction, "Cluster completed",
                  0, 0, "Mode=" + EnumToString(g_clusters[i].mode));
         g_clusters[i].Reset();
         continue;
      }
      
      // ── Active cluster management ────────────────────────────────
      switch(g_clusters[i].state)
      {
         case CLUSTER_LOCKED:
            ManageHedgeLock(i);
            break;
         
         case CLUSTER_NORMAL:
         case CLUSTER_UNLOCKING:
            // Check hedge lock trigger first (higher priority)
            CheckHedgeLock(i);
            
            // If still normal/unlocking after hedge check, manage grid
            if(g_clusters[i].state == CLUSTER_NORMAL || 
               g_clusters[i].state == CLUSTER_UNLOCKING)
            {
               CheckLegTPs(i);
               
               if(ShouldOpenNextLeg(i))
                  OpenNextLeg(i);
               
               if(IsClusterComplete(i))
                  g_clusters[i].state = CLUSTER_CLOSED;
            }
            break;
         
         case CLUSTER_OPENING:
         case CLUSTER_CLOSING:
            // Transitional states — managed by the functions that set them
            break;
         
         default:
            break;
      }
   }
   
   // ════════════════════════════════════════════════════════════════
   // PRIORITY 6: Update Market State (on new bar)
   // ════════════════════════════════════════════════════════════════
   if(IsNewBar(PERIOD_M15))
      UpdateMarketState();
   
   // Also check ATR on its own timeframe if different from M15
   if(ATRTimeframe != PERIOD_M15 && IsNewBar(ATRTimeframe))
      UpdateMarketState();
   
   // Also check ADX on its own timeframe if different
   if(ADXTimeframe != PERIOD_M15 && ADXTimeframe != ATRTimeframe && IsNewBar(ADXTimeframe))
      UpdateMarketState();
   
   // ════════════════════════════════════════════════════════════════
   // PRIORITY 7: Open New Clusters
   // ════════════════════════════════════════════════════════════════
   if(!CanOpenNewCluster())
      return;
   
   int freeSlot = FindFreeClusterSlot();
   if(freeSlot < 0)
      return; // All slots occupied
   
   ENUM_GRID_MODE mode = GetCurrentMode();
   
   if(mode == MODE_DIRECTIONAL)
   {
      ENUM_CLUSTER_DIRECTION dir = GetTrendDirection();
      if(dir != DIR_NONE && IsPullbackEntry())
      {
         if(OpenCluster(freeSlot, mode, dir))
         {
            LogToCSV("CLUSTER_OPEN", g_clusters[freeSlot].clusterSeq, TIER_ID,
                     (int)dir, "Directional",
                     SymbolInfoDouble(_Symbol, SYMBOL_BID),
                     g_clusters[freeSlot].baseLot,
                     "GridStep=" + DoubleToString(g_clusters[freeSlot].gridStep, 2) +
                     " ADX=" + DoubleToString(g_currentADX, 1));
         }
      }
   }
   else if(mode == MODE_RANGE)
   {
      ENUM_CLUSTER_DIRECTION dir = DIR_NONE;
      if(IsBollingerEntry(dir) && dir != DIR_NONE)
      {
         if(OpenCluster(freeSlot, mode, dir))
         {
            LogToCSV("CLUSTER_OPEN", g_clusters[freeSlot].clusterSeq, TIER_ID,
                     (int)dir, "Range",
                     SymbolInfoDouble(_Symbol, SYMBOL_BID),
                     g_clusters[freeSlot].baseLot,
                     "GridStep=" + DoubleToString(g_clusters[freeSlot].gridStep, 2) +
                     " ADX=" + DoubleToString(g_currentADX, 1));
         }
      }
   }
   // MODE_NEUTRAL: no new clusters — controlled by CanOpenNewCluster()
}

//+------------------------------------------------------------------+
//| Timer event handler (optional — for news cache refresh)            |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Gate 3: Periodic news cache refresh if using timer-based approach
   // Alternative: news check in OnTick() with interval guard
}

//+------------------------------------------------------------------+
//| Trade transaction handler — detects TP fills in real time          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // We're interested in DEAL_ADD events — these fire when a deal executes
   // (including when broker closes a position at TP)
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   
   // Get the deal ticket from the transaction
   ulong dealTicket = trans.deal;
   if(dealTicket == 0)
      return;
   
   // Select the deal from history
   if(!HistoryDealSelect(dealTicket))
      return;
   
   // Check if this deal is an exit (close) deal
   long dealEntry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_INOUT)
      return; // Not a close — probably our own entry order
   
   // Check if magic number is in our range
   long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   if(dealMagic < MagicBase || dealMagic > MagicBase + 99999)
      return; // Not our deal
   
   // A position managed by our EA was closed
   // The CheckLegTPs() function in the next OnTick() call will pick this up
   // and update the cluster tracking. We just log it here for immediate feedback.
   
   double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                     + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                     + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   double dealPrice  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   double dealVolume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   
   Print("DEAL DETECTED — Ticket:", dealTicket,
         " Magic:", dealMagic,
         " Price:$", DoubleToString(dealPrice, 2),
         " Volume:", DoubleToString(dealVolume, 2),
         " P&L:$", DoubleToString(dealProfit, 2),
         " Entry:", EnumToString((ENUM_DEAL_ENTRY)dealEntry));
}

//+------------------------------------------------------------------+
//| END OF FILE                                                        |
//+------------------------------------------------------------------+
