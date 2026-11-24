# 1.2.1

- Fixed the run timer not starting on the first writ hand-in. `QUEST_TURNED_IN` was recorded by the daily-completion tracker first, which marked the step done as a "daily" update and skipped the clock. The clock now starts on the first real turn-in (quest event, bag fallback, or a daily mark that came from a turn-in), and also if you click Skip / Mark done after handing in. If a run is already past the first step with the timer still stopped, it starts at the next real turn-in.

# 1.2.0

Planner
- Ranks Craftsman's Writs by reputation per gold using live Auctionator prices.
- Max per writ and Budget gold pick the cheapest qualifying plan; Apply limits updates the lists if you do not press Enter.
- Qualify line under #3 shows how many writs fit the limits and estimated reputation (including whether the run reaches the next standing).
- Net column shows cost after the turn-in gold reward (learned in-game the first time you view or complete a writ).
- Show all writs can list every filtered writ, while #4 and #5 stay on the plan.

Shopping and route
- Section 4 shopping list and section 5 route are built from the current plan.
- AH shopping list creates or updates an Auctionator "WritRunner" list when the plan changes.
- Route is a nearest-neighbor tour with travel hints between zones and continents.
- Waypoint next sets a map waypoint (and TomTom, if loaded).

Run tracker
- Start run snapshots the plan and opens a compact tracker with a click-to-open button for the next writ only.
- Numbered world-map pins for each stop; current step is highlighted.
- Reputation bar in the main window and on the tracker; each turn-in is checked so a missed-rep writ is flagged.
- Minimap button (left-click opens WritRunner, right-click toggles the tracker).
- Run timer and distance start at the first real turn-in, not when you click Start run.
- Upcoming tracker steps whose items are not in your bags are shown in red.

Bag check
- After buying and looting mail, Start run (or Check bags / `/writs check`) counts every remaining plan item in your bags.
- A confirm popup lists any missing items (have/need and which writ) and reminds you that mailbox items do not count. Start anyway or Cancel; Check bags uses OK.
- If everything is present, Start run proceeds immediately.

Plan Confirm and Reset
- Checkboxes in #3 stage removals and do not change #4 or #5 until you click Confirm (a popup lists the writs that will be removed).
- Reset under #3 restores only writs you removed there, not real turn-ins. Turned-in rows are locked.
- The status line next to Reset splits "X turned in, Y removed."

Commands
- `/writs` or `/writrunner` toggles the window. `/writs start`, `/writs check`, `/writs track`, `/writs end`, `/writs minimap`.
- `/writs reset` asks for confirmation, then clears all of today's completed writs (turn-ins and #3 removals) and ends any active run.
- `/writs help` lists these commands.
- The daily list also clears on its own at the server daily reset.

Optional: Auctionator (for prices) and TomTom (for waypoints). Interface 16001 (WoW: Forever).
