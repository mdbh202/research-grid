// Existing code...
datetime    g_lastBarTimeADX    = 0;
datetime    g_lastMarketStateUpdate = 0; // Guards against double-fire on same M15 bar

// ════════════════════════════════════════════════════════════════
// PRIORITY 6: Update Market State (on new bar)
// Guard ensures UpdateMarketState() fires at most once per M15 bar,
// even when ATR (D1) and ADX (H1) bars also open on the same tick.
// ════════════════════════════════════════════════════════════════
{
   bool needsUpdate = false;
   if(IsNewBar(PERIOD_M15))                                              needsUpdate = true;
   if(ATRTimeframe != PERIOD_M15 && IsNewBar(ATRTimeframe))             needsUpdate = true;
   if(ADXTimeframe != PERIOD_M15 && ADXTimeframe != ATRTimeframe
      && IsNewBar(ADXTimeframe))                                         needsUpdate = true;

   if(needsUpdate)
   {
      datetime currentM15Bar = iTime(_Symbol, PERIOD_M15, 0);
      if(currentM15Bar != g_lastMarketStateUpdate)
      {
         g_lastMarketStateUpdate = currentM15Bar;
         UpdateMarketState();
      }
   }
}