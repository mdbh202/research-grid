# Grid EA — LLM Context Prompt (Sonnet 4.6)

> **Purpose:** This document is the master context prompt for any LLM session working on the Grid Trading Research EA. Paste this at the start of every conversation. It contains the full architectural spec, known bug history, current state, optimization parameters, and coding conventions. Written for Claude Sonnet 4.6 — uses explicit structured headings, numbered constraints, and concrete examples to minimize ambiguity.

---

## 1. PROJECT IDENTITY

- **Repository:** `mdbh202/research-grid`
- **File:** `grid_trading_research.mq5` (single-file EA, ~3200 lines)
- **Language:** MQL5 (MetaTrader 5)
- **Account type:** MT5 **Hedging** account (NOT netting — multiple positions on same symbol allowed)
- **Target symbol:** XAUUSD (Gold, contract size = 100 oz)
- **Broker:** PepperstoneUK-Demo (important for filling mode — see §6)
- **Tier:** Intraday (Tier 2, embedded in MagicBase = 120000)

---

## 2. ARCHITECTURE OVERVIEW

The EA is a **directional grid** with two operating modes, determined by ADX:

```
ADX < ADXRangeThreshold (22)  →  MODE_RANGE       → Bollinger Band mean-reversion entries
ADX > ADXTrendThreshold (25)  →  MODE_DIRECTIONAL  → EMA pullback trend-following entries  
ADXRangeThreshold ≤ ADX ≤ ADXTrendThreshold → MODE_NEUTRAL → no new clusters
```

### Core Concepts

| Term | Definition |
|------|-----------|
| **Cluster** | A group of up to `MaxLegs` (3–7) positions in the same direction, plus optional hedge. One trading unit. |
| **Leg** | A single position within a cluster. Leg 1 is the entry; legs 2+ are added as price moves adverse by `GridStep`. |
| **Grid Step** | Distance between legs: `clamp(ATR × GridStepMultiplier, GridStepFloor, GridStepCap)`. Frozen at cluster open. |
| **Hedge Lock** | Counter-position placed when price moves `HedgeLockTriggerMultiplier × GridStep` beyond the last leg. Neutralizes exposure. |
| **Base Lot** | `(Equity × RiskPerCluster) / (WeightedLegs × 3 × GridStep × ContractSize)`. Rounded down to volume step. |

### Module Map

| Module | Lines (approx) | Responsibility |
|--------|----------------|----------------|
| A: Initialization | 280–680 | OnInit, ValidateInputs, InitializeIndicators, CalculateSessionTimes |
| B: Market State | 700–1115 | ATR/ADX/EMA/BB reading, mode switching, entry signals, diagnostics |
| C: Cluster Management | 1120–1720 | CanOpenNewCluster (13 checks), OpenCluster, OpenNextLeg, ManageCluster, CheckLegTPs, CloseCluster |
| D: Risk Management | 1725–2275 | CalculateBaseLot, GetLegLot, PortfolioHeat, KillSwitch, ProtectionMode, HedgeLock, UnlockHedge |
| E: News Filter | 2395–2420 | Stubs (Gate 3) |
| F: Order Execution | 2425–2620 | SendMarketOrder, ClosePosition, ClosePositionByMagic |
| G: Logging & Alerts | 2625–2695 | LogToCSV, NotifyUser |
| H: State Persistence | 2700–2800 | SaveState, LoadState, ReconstructClustersFromPositions |
| Main: OnTick | 2985–3180 | Master control loop with priority ordering |
| Utilities | 2800–2980 | IsNewBar, IsInSession, IsBeforeCutoff, IsSuspended, magic number builders |

### OnTick Priority Order (CRITICAL — do not reorder)

```
1. CheckKillSwitch()          → if active: return (nothing else runs)
2. CheckProtectionMode()      → monitors only; does NOT block existing cluster management
3. Weekend Safety             → Friday close: execute, return
4. Session Time Exit          → past close: close all, return  
5. Manage Existing Clusters   → hedge locks, leg TPs, next legs, completion
6. Update Market State        → on new M15/ATR/ADX bar only
7. Open New Clusters          → CanOpenNewCluster() gate → entry signals → OpenCluster()
```

**IMPORTANT:** Protection mode does NOT early-return. It only blocks new cluster opens via `CanOpenNewCluster()` Check 5. Existing clusters must still be managed (TPs checked, hedges managed, session exits honored). This was a bug that was fixed.

---

## 3. DATA STRUCTURES

```mql5
struct LegInfo {
   ulong ticket; int legNumber; double entryPrice, lotSize, tpPrice;
   bool isOpen, isHedge; datetime openTime, closeTime; double closePL;
};

struct ClusterInfo {
   ENUM_CLUSTER_STATE state; ENUM_GRID_MODE mode; ENUM_CLUSTER_DIRECTION direction;
   int clusterSeq, magicBase, hedgeMagic;
   double gridStep, baseLot, tpDistance;
   int legsOpened, legsClosed, locksActive;
   double lastLegPrice, lockPrice;
   datetime openTime, lockTime;
   double totalLotsLong, totalLotsShort;
   LegInfo legs[MAX_LEGS_ABSOLUTE + 1];  // index 0 = hedge, 1–7 = grid legs
};

ClusterInfo g_clusters[MAX_CLUSTERS_ABSOLUTE];  // MAX_CLUSTERS_ABSOLUTE = 5
```

### Magic Number Scheme

```
MAGIC = MagicBase(120000) + DirectionID(×1000) + ClusterSeq(001–999)
Hedge: MagicBase + 3000 + ClusterSeq
```

---

## 4. INPUT PARAMETERS (all 7 groups)

### Group 1: Account & Risk
| Input | Default | Range | Unit |
|-------|---------|-------|------|
| `RiskPerCluster` | 0.03 | 0.01–0.05 | fraction of equity |
| `MaxConcurrentClusters` | 3 | 1–5 | count |
| `KillSwitchPct` | 0.05 | — | fraction of balance |
| `ProtectionDrawdownPct` | 0.25 | — | fraction of peak equity |
| `MagicBase` | 120000 | — | fixed |

### Group 2: Grid Structure
| Input | Default | Range | Unit |
|-------|---------|-------|------|
| `GridStepMultiplier` | 0.25 | 0.15–0.40 | ATR multiplier |
| `GridStepFloor` | 5.00 | — | USD |
| `GridStepCap` | 18.00 | — | USD |
| `MaxLegs` | 5 | 3–7 | count |
| `TPMultiplier` | 1.50 | 1.0–3.0 | GridStep multiplier |
| `LegScalingStart` | 4 | 3–7 | leg number |
| `LegScalingFactor` | 1.50 | — | lot multiplier |
| `ATRPeriod` | 14 | 7–30 | bars |
| `ATRTimeframe` | PERIOD_D1 | — | — |
| `SuspendATRPctThreshold` | 6.0 | — | % of price |

### Group 3: Mode Switching
| Input | Default | Range | Unit |
|-------|---------|-------|------|
| `ADXPeriod` | 14 | 7–30 | bars |
| `ADXTimeframe` | PERIOD_H1 | — | — |
| `ADXRangeThreshold` | 22.0 | — | ADX value |
| `ADXTrendThreshold` | 25.0 | — | ADX value |
| `TrendEMAPeriod` | 20 | — | bars |
| `TrendEMATimeframe` | PERIOD_M15 | — | — |
| `BBPeriod` | 20 | — | bars |
| `BBDeviation` | 2.0 | — | std dev |
| `BBTimeframe` | PERIOD_M15 | — | — |

### Group 4: Hedge Lock
| Input | Default | Range | Unit |
|-------|---------|-------|------|
| `HedgeLockEnabled` | true | — | bool |
| `HedgeLockTriggerMultiplier` | 2.0 | 1.5–3.0 | GridStep multiplier |
| `HedgeUnlockMultiplier` | 1.0 | 0.5–2.0 | GridStep multiplier |
| `HedgeForceCloseMultiplier` | 1.0 | 0.5–2.0 | GridStep multiplier |
| `MaxLocksPerCluster` | 1 | — | count |

### Group 5: Session & Time (all in UTC, adjusted by BrokerGMTOffset)
| Input | Default |
|-------|---------|
| `SessionStartHour/Minute` | 02:00 |
| `NewClusterCutoffHour/Minute` | 17:00 |
| `SessionCloseHour/Minute` | 21:00 |
| `FridayCloseHour/Minute` | 18:30 |
| `BrokerGMTOffset` | 0 |

### Group 6: News Filter (stubs — Gate 3)
### Group 7: Logging & Alerts

---

## 5. INTERNAL CONSTANTS (non-configurable)

```
MAX_LOT_MULTIPLIER          = 2.0      // No leg > 2× base lot
MAX_PORTFOLIO_HEAT_PCT      = 0.09     // 3 clusters × 3% = 9%
ORDERSEND_MAX_RETRIES       = 3
ORDERSEND_RETRY_DELAY_MS    = 500
HEDGE_MAGIC_OFFSET          = 3000
SPREAD_TO_STEP_MAX_RATIO    = 0.15
MARGIN_SAFETY_FACTOR        = 0.80
MAX_LEGS_ABSOLUTE           = 7        // Array sizing
MAX_CLUSTERS_ABSOLUTE       = 5        // Array sizing
MIN_BARS_FOR_INDICATOR      = 30
```

---

## 6. KNOWN BUG HISTORY (FIXED)

These bugs were identified and fixed. Listed here so you do NOT re-introduce them:

### Bug 1: Filling Mode — FIXED
**Was:** `SendMarketOrder()` and `ClosePosition()` only toggled FOK ↔ IOC on retcode 10030. Pepperstone XAUUSD requires `ORDER_FILLING_RETURN`.
**Fix:** 3-way rotation: FOK → IOC → RETURN, using `SYMBOL_FILLING_MODE` bitmask to detect supported modes. RETURN is tried when neither FOK nor IOC is reported.

### Bug 2: ATR Suspension — FIXED  
**Was:** `IsSuspended()` compared raw ATR dollars against `SuspendATRThreshold`. With ATR=$191 and threshold=6.0 (meant as 6%), trading was permanently suspended.
**Fix:** Renamed to `SuspendATRPctThreshold`. Now calculates `(ATR / Bid) × 100` and compares percentage.

### Bug 3: Duplicate return in OnInit — FIXED
**Was:** Two `return(INIT_SUCCEEDED)` at end of OnInit. Second was dead code.

### Bug 4: Protection Mode blocking cluster management — FIXED
**Was:** `if(g_protectionModeActive) return;` in OnTick blocked ALL activity. Existing clusters couldn't be managed, TPs couldn't fire, session exits wouldn't execute.
**Fix:** Removed the early return. Protection mode only blocks new cluster opens via `CanOpenNewCluster()` Check 5.

---

## 7. LATEST BACKTEST RESULTS (post-bug-fix baseline pending)

### Pre-fix backtest (2025.06.01–2026.02.20, $10,000 initial):
| Metric | Value | Assessment |
|--------|-------|------------|
| Total Net Profit | -$163.29 | Losing |
| Profit Factor | 0.81 | Below breakeven |
| Total Trades | 49 | Low sample |
| Win Rate (Short) | 31.03% (29 trades) | — |
| Win Rate (Long) | 80.00% (20 trades) | — |
| Max Equity DD | 4.37% ($442) | Acceptable |
| Sharpe Ratio | -1.78 | Poor |
| Recovery Factor | -0.37 | Poor |
| Largest Win | $63.12 | — |
| Largest Loss | -$106.02 | — |

**Note:** This backtest was run WITH the filling mode bug (many clusters failed to open) and the ATR suspension bug (periods of no trading). The post-fix numbers will look very different.

---

## 8. OPTIMIZATION PARAMETERS

### 🔒 LOCKED (do NOT optimize)
`KillSwitchPct`, `ProtectionDrawdownPct`, `MagicBase`, `ATRPeriod`, `ADXPeriod`, `BBPeriod`, `BBDeviation`, `MaxLocksPerCluster`, `BrokerGMTOffset`, all Session/Time params, all News params, Logging params.

### ✅ OPTIMIZE (12 parameters)

| # | Parameter | Start | Step | Stop | Default |
|---|-----------|-------|------|------|---------|
| 1 | `RiskPerCluster` | 0.01 | 0.005 | 0.03 | 0.03 |
| 2 | `MaxConcurrentClusters` | 1 | 1 | 3 | 3 |
| 3 | `GridStepMultiplier` | 0.15 | 0.05 | 0.35 | 0.25 |
| 4 | `GridStepFloor` | 8 | 3 | 20 | 11 |
| 5 | `GridStepCap` | 25 | 5 | 45 | 40 |
| 6 | `MaxLegs` | 3 | 1 | 5 | 3 |
| 7 | `TPMultiplier` | 1.0 | 0.25 | 2.0 | 1.5 |
| 8 | `ADXRangeThreshold` | 18 | 2 | 24 | 22 |
| 9 | `ADXTrendThreshold` | 23 | 2 | 30 | 25 |
| 10 | `TrendEMAPeriod` | 14 | 6 | 32 | 20 |
| 11 | `HedgeLockTriggerMultiplier` | 1.5 | 0.5 | 3.0 | 2.0 |
| 12 | `LegScalingFactor` | 1.0 | 0.25 | 2.0 | 1.5 |

### Anti-Overfitting Protocol
1. **Phase 1:** Genetic algorithm, all 12 params, ≥10,000 iterations
2. **Phase 2:** Top 5 → narrow ±1 step → exhaustive
3. **Phase 3:** Walk-forward: in-sample 2025.06–2026.01 / out-of-sample 2026.02
4. **Red flags:** PF > 3.0, < 30 trades, params at boundary, max aggression combo

---

## 9. STUB FUNCTIONS (Gate 3 — not yet implemented)

These return hardcoded values. Do NOT call them as if they work:

| Function | Current Return | Intended Behavior |
|----------|---------------|-------------------|
| `CheckSpreadViability()` | `true` | Compare spread/step ratio to 0.15 |
| `CheckMarginSufficiency()` | `true` | Verify free margin > required × 0.80 |
| `IsNewsWindow()` | `false` | Check MQL5 calendar for high-impact events |
| `ExecuteWeekendSafety()` | no-op | Close all intraday clusters on Friday |
| `ExecuteMondayUnwind()` | no-op | Close weekend hedges |
| `ExecuteKillSwitch()` | no-op | Legacy stub, actual logic is in `CheckKillSwitch()` |
| `ExecuteProtectionMode()` | no-op | Legacy stub, actual logic is in `CheckProtectionMode()` |
| `ExecuteHedgeLock()` | no-op | Legacy stub, actual logic is in `CheckHedgeLock()` |
| `ExecuteHedgeForceClose()` | no-op | Legacy stub, actual logic is in `CloseCluster()` |

---

## 10. MQL5 CODING CONVENTIONS

When writing or modifying code in this EA, follow these conventions:

1. **Error handling pattern:** Always use `Print("ERROR: ...")` or `Print("WARNING: ...")` prefix. Critical failures that could strand positions use `Print("CRITICAL: ...")`.
2. **Logging:** All state changes and trade events must call `LogToCSV()`. Format: `LogToCSV(eventType, clusterSeq, TIER_ID, direction, action, price, lots, details)`.
3. **Array indexing:** `legs[0]` = hedge leg. `legs[1]` through `legs[MaxLegs]` = grid legs. Never access `legs[MaxLegs+1]` or beyond.
4. **Magic numbers:** Use `BuildMagicNumber()` and `BuildHedgeMagic()`. Never hardcode magic values.
5. **Price selection:** BUY orders use ASK. SELL orders use BID. Hedge direction is opposite of cluster direction.
6. **Filling mode:** Must try FOK, IOC, and RETURN. Use `SYMBOL_FILLING_MODE` bitmask. On retcode 10030, rotate to next mode.
7. **Volume rounding:** Always `MathFloor(lot / volumeStep) * volumeStep`. Check against `SYMBOL_VOLUME_MIN` and `SYMBOL_VOLUME_MAX`.
8. **TP normalization:** `MathRound(tp / tickSize) * tickSize`.
9. **Retry pattern:** Up to `ORDERSEND_MAX_RETRIES` (3) with `ORDERSEND_RETRY_DELAY_MS` (500ms) between. Refresh price on each retry.
10. **State transitions:** Only `CloseCluster()` and the OnTick loop should transition cluster states. Individual functions signal completion; the caller updates state.
11. **Global variable persistence:** Use `GetGlobalVarName()` prefix for all `GlobalVariableSet/Get` calls. Format: `GridEA_{MagicBase}_{suffix}`.
12. **Warning throttling:** `CalculateBaseLot()` throttles "insufficient equity" warnings to prevent log spam. Other high-frequency warnings should follow the same pattern.

---

## 11. XAUUSD MARKET CONTEXT

- **Price range (2025–2026):** ~$2,400–$5,000+
- **Typical daily ATR:** $30–$200 depending on volatility regime
- **Contract size:** 100 oz per lot
- **Tick size:** 0.01 (some brokers 0.001)
- **Spread:** 15–50 points typical (Pepperstone)
- **Filling:** Pepperstone requires `ORDER_FILLING_RETURN` for XAUUSD
- **Session:** Most liquid 08:00–17:00 UTC (London + NY overlap)

---

## 12. TASK INSTRUCTIONS FOR THE LLM

When asked to modify this EA:

1. **Always read the relevant module first.** Don't guess at line numbers — search for function names.
2. **Preserve the OnTick priority order.** Never move risk checks below cluster management.
3. **Never remove safety checks** from `CanOpenNewCluster()` — it has 13 checks for a reason.
4. **Test filling mode changes** against all three modes (FOK, IOC, RETURN).
5. **When adding new input parameters:** Add validation in `ValidateInputs()`, add to `DiagnosticPrintMarketState()`, and update this context document.
6. **When modifying cluster state transitions:** Verify the state machine: IDLE → OPENING → NORMAL → (LOCKED ↔ UNLOCKING) → CLOSING → CLOSED → Reset to IDLE.
7. **Gate system:** Features are gated. Gate 1 = architecture. Gate 2 = basic execution. Gate 3 = hardened execution (spreads, margin, news). Don't implement ungated features without explicit instruction.
8. **For optimization work:** Refer to §8. Never optimize locked parameters. Always validate ADXRangeThreshold < ADXTrendThreshold.

---

*Last updated: 2026-02-24. Reflects bug fixes from PR #1 (filling mode, ATR suspension, duplicate return, protection mode).*