# 1.3.5

- **Start run checks bags only.** If any writ or fill item is missing from your bags, the tracker does not start. The popup lists each missing item and where it is: in the bank, in the mailbox (last inbox scan, plus today's purchases not yet collected), or not owned, with a hint to visit the bank or mailbox and Start run again. Buttons are **Check again** and **Close**.
- A checkbox in #5, **Allow starting with missing items** (off by default, saved), restores the old **Start anyway** button.
- **Check bags** uses the same location breakdown. The locked shopping list in #4 shows compact tags such as `have 0 (bank 1, mail 1)` and ticks off only items actually in bags.
- Opening the bank or mailbox prints a one-line chat hint if a plan item is sitting there. Mail is scanned on MAIL_SHOW / MAIL_INBOX_UPDATE only while the mailbox is open (no taint, no secure hooks).

# 1.3.4

- Step-by-step buyer compares out-of-pocket cost to the planned cost for the quantity you actually need (scanned unit × need). It no longer multiplies the scanned price by a listing's stack size. A 22-stack at 53s 50c when you need one (scanned 49s 50c) is 4s more (+8%, red), not "10g 35s 50c lower." Per-unit price is shown as secondary info. Extra items from a stack are labeled (e.g. "extra 21") and are not counted as savings.
- Listing selection picks the combination with the lowest total buyout to cover the need: a single at 55s only beats a 22-stack at 53s 50c if it is cheaper overall, and vice versa.
- "Spent X of planned Y" uses this plan's out-of-pocket totals against scanned unit × plan quantity, not the daily buy log and not a prorated stack unit price. The ledger uses the same basis (a 22-stack bought to fill a need of 1 counts the full buyout).

# 1.3.3

- The Auction House title-bar button now attaches to the classic AuctionFrame (Blizzard_AuctionUI) that WoW: Forever actually shows ("Browse Auctions", Search, bottom Browse/Bids/Auctions tabs). 1.3.2 only looked for AuctionHouseFrame, which is not present, so the button never appeared. It is created on AUCTION_HOUSE_SHOW, on ADDON_LOADED of Blizzard_AuctionUI (and Blizzard_AuctionHouseUI if that loads), and via HookScript OnShow on the frame. Anchored left of AuctionFrameCloseButton in the title bar (or TOPRIGHT of the frame if no close button is found), above the Search button and away from Auctionator's bottom tabs.
- `/writs ahbutton` prints which frame was found, the anchor, and whether the button is shown. `/writs buy` is unchanged and still works when the AH is open.
- AH-open detection (step buyer, #4 Buy button, ledger purchase window, MultiSearch fallback) now treats AuctionFrame and AuctionHouseFrame as open. Closing the AH still stops an in-progress buy via AUCTION_HOUSE_CLOSED.

# 1.3.2

- **Use writs in my bags** (checkbox in #2, next to Apply limits): named writs already in your bags or the bank are added to the plan at no writ cost. If the fill item is also on hand, it is not added to the shopping list; otherwise only that item is. Writs whose turn-in NPC has no known path are skipped, with the reason under #3, and are not added. Owned rows are tagged "owned" or "in bank". The setting is saved. While the box is ticked and the plan is not locked, bag changes rebuild the plan; a locked plan stays frozen until you Re-plan.
- **Buy step by step on the Auction House**: a 28×28 note-icon button sits on the AH title bar, just left of the close button (away from Auctionator's bottom tabs). It is created the first time the AH opens, parented to AuctionHouseFrame, and uses HookScript only. The badge shows how many locked-list items are still short. The button is disabled, with a tooltip, until a plan is locked in #4.
- **Estimated pouch return and net gold** in #3: each writ shows an approximate net (~cost minus expected Coin Pouch and any direct quest gold). Totals appear on the qualify line. A **Rank by net gold** checkbox (left of Show all writs) ranks by reputation per estimated net instead of per cost; off by default so existing plans stay the same. Estimates are marked ~.
- Pouch averages are learned in the ledger when a Coin Pouch's gold can be tied to a turn-in (pouch item id, or the pouch opened right after QUEST_TURNED_IN). Until a tier has a sample, only Artisan is seeded (74.56 silver = 7456 copper, Wowhead Looter average; ConquestCapped/Willo also reported ~75s). Journeyman and Expert are not seeded: published ranges disagree (Wowhead Looter Journeyman 5–19s / Expert avg 36s, comments suggesting higher; ConquestCapped 15–21 Nov 2026 Journeyman 22–45s / Expert 50–90s), and there were no samples in SavedVariables. Those tiers show ? in Net until you open pouches after a turn-in.

# 1.3.1

- The actual price paid for each item is saved (per item, for the day, in SavedVariables, so it survives /reload). Buy step by step always records it. Purchases from the Auctionator list or the default Auction House window are also counted when the gold leaves and the item appears in your bags (commodities usually do). Items that only arrive in the mailbox later are not counted unless you bought them with Buy step by step.
- When the last writ of a run is turned in, a popup reminds you to open every Coin Pouch in your bags. It shows how many are still unopened and updates as you open them, plus gold counted so far. Coin Pouches are items 284583–284586 (same name, different ids by writ group).
- Gold from opening those pouches is added to the run (money gained right after a pouch leaves your bags). Direct quest gold from QUEST_TURNED_IN is also added; Forever writs usually pay 0 here, with the gold in the pouch instead.
- End run shows a summary: actual spend, gold from pouches, quest gold, net gain or loss (green/red), that spend against the planned cost, and reputation if it was tracked. If pouches are still unopened, it warns first so you can open them. The last 10 runs are kept; open them with /writs history or the History button on the tracker. The tracker also shows a live Net figure during the run.

# 1.3.0

- New **Buy step by step** (button in #4, or `/writs buy`). With the Auction House open and the plan locked, a WritRunner popup walks the shopping list one item at a time, writ by writ so each item is followed by the one it pairs with. It shows the icon, quantity still needed (minus bags and anything already bought today), the price scanned when the list was made, and the live price from a fresh AH search for the cheapest listings that cover what you need, with the difference in green (cheaper) or red (dearer).
- **Accept** buys it. Commodities buy the whole amount in one click; if the price rises between the quote and the confirm, the popup shows the new total and waits for another click. Separate listings take one click per listing ("Buy 1 of 3").
- **Reject** (click twice) drops every writ that needs the item, and the item it pairs with, from the locked plan. The route is rebuilt and the Auctionator list updated to match. **Skip** brings the item back after the rest of the list; **Stop** closes the buyer and keeps what you bought.
- Handles items with no listings (Reject, Skip or search again), partial quantities (buys what is listed, the rest stays), not enough gold (Accept disabled with what you need vs have), purchase failures and AH errors (shows the reason and searches again), and shows progress (item X of Y, spent vs planned).
- Purchases are logged per day, so items still in the mailbox count as bought in #4 and in the buyer, across Re-plan and /reload.
- Uses the modern C_AuctionHouse API that WoW: Forever runs (SendSearchQuery, StartCommoditiesPurchase / ConfirmCommoditiesPurchase, PlaceBid). The legacy browse API does not fire on this client.

# 1.2.3

- Fixed the shopping list changing while you shop. Every Auctionator search updates its price database, and WritRunner used to re-pick writs on each update and silently rewrite the Auctionator "WritRunner" list. When prices crept up as you bought the cheapest listings, writs fell out of the budget and their items vanished from the list mid-shop. Now clicking AH shopping list in #4 locks the plan: price updates, limit changes and opening the window no longer change the plan or the Auctionator list.
- New Re-plan button in #4 (with a confirm popup showing which writs would be added or removed and the new cost) unlocks, re-picks with current prices, and replaces the Auctionator list. The lock also clears at the daily reset and with /writs reset.
- #4 shows a "Locked" banner, a notice when prices or limits have changed since the list was made, and ticks items off as they land in your bags ([x] / have N). Turned-in writs drop out of the route; nothing is added.
- Clicking AH shopping list again while locked re-sends the same list (handy if you deleted it in Auctionator).
- Auctionator database updates are coalesced so a burst of AH searches refreshes the window once.
- The Auctionator list has never set a max price on its entries (exact-name searches only), so purchases are not price-capped by WritRunner.

# 1.2.2

- Faction-aware Classic travel: routes use Horde or Alliance flight points, ground runs into zones with no own-faction FP (Horde is no longer told to "Fly to Duskwood"), and zeppelin/boat crossings with realistic times. Ordering is shortest-path (Dijkstra) plus nearest-neighbor and 2-opt on those times, so a southern Eastern Kingdoms run prefers Swamp of Sorrows → run to Duskwood → Stranglethorn, then the Grom'gol zeppelin or Booty Bay boat to Kalimdor.
- `/writs reroute` rebuilds the remaining steps of an active run from your current position without losing progress. A `/reload` also reroutes the remaining steps.

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
