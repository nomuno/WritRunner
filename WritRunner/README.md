# WritRunner

A World of Warcraft: Forever addon that ranks Craftsman's Writs by reputation per gold, using live Auctionator prices, then builds an auction-house shopping list and a turn-in route. A compact tracker runs the route like a quest objective list, with numbered world-map pins and a click-to-open button for the next writ only (so you do not have to fill your quest log and bags all at once).

**Author:** Darth
**Version:** 1.3.5
**Interface:** 16001 (Forever / game 1.60.1)
**Optional:** Auctionator, TomTom

The ranking window and Auctionator pricing have been used in-game. The 1.1.0 tracker, map pins, secure item button, and improved routing are new and still need a live pass. See [Known gaps](#known-gaps).

## Install

1. Grab `WritRunner.zip` (or this `WritRunner` folder).
2. Extract so the folder lands at:

   `World of Warcraft/_forever_/Interface/AddOns/WritRunner/`

   The zip already contains a top-level `WritRunner/` folder. Do not nest it twice (`AddOns/WritRunner/WritRunner/`). You should see `WritRunner.toc` directly inside `AddOns/WritRunner/`.

3. Restart the Forever client (or `/reload` if the addon was already present).
4. Install a Forever-tagged Auctionator build (interface 16001) if you want prices. WritRunner still loads without it, but every cost is shown as unknown — it never invents a price.

Classic Era or other-project Auctionator builds will not load on Forever (interface 11509 vs 16001). Use a Forever-compatible Auctionator.

## Usage

### Ranking window

- Slash commands: `/writs` or `/writrunner` toggles the main window.
- `/writs start` starts a run from the current plan (it checks your bags first). `/writs check` pops up whether every plan item is in your bags. `/writs track` toggles the tracker. `/writs end` ends the run. `/writs reset` asks for confirmation, then clears all of today's completed writs (turn-ins and #3 removals) and ends any active run. `/writs help` lists these commands.
- The list is sorted by reputation per gold (known prices first). Missing Auctionator prices are labeled **unknown**.
- **Max gold** hides any writ whose all-in cost (writ + required item × count) is above that gold amount.
- **Budget gold** greedily picks the best remaining writs that still fit the budget. The shopping list and route are built from that plan. Leave it blank to include every currently listed writ that has a known price.
- **Hide unconfirmed** hides turn-ins that are not fully confirmed against ConquestCapped (`cc`). Partial, Wowhead, and unmapped turn-ins stay hidden until you uncheck this.
- **Hide done today** hides writs you have already turned in (or marked done) today.
- **Sealed envelopes** shows expected cost for Sealed Journeyman's / Expert's / Artisan's Writ (item IDs 262888 / 262889 / 262890): sealed AH price + the average known fill (required-item) cost of that tier.
- Tick the box on a row to **stage** a writ for removal. #4 and #5 do not change until you click **Confirm** under the list (a popup lists the N writs that will be removed). **Reset** next to it clears staged ticks and restores only writs you removed in #3 (with a confirm popup). Real turn-ins (`QUEST_TURNED_IN` and run steps) are recorded immediately, shown locked in #3, and are not restored by that Reset. To clear both turn-ins and removals, type `/writs reset` in chat (a confirm popup will ask first).
- The daily list (and any active run) resets at the server daily reset (`C_DateAndTime.GetSecondsUntilDailyReset`, with `GetQuestResetTime` as a fallback).
- **Waypoint next** sets a Blizzard map waypoint (`C_Map.SetUserWaypoint` + super-tracking) for the selected row, or for the next unfinished stop in the route, when coordinates exist. TomTom is used as well if it is loaded.
- **Shopping-list lock (1.2.3):** clicking **AH shopping list** locks the plan. Auctionator price updates, limit changes and reopening the window no longer re-pick writs or rewrite the Auctionator list. #4 shows a Locked banner, a notice when prices changed, and ticks items off from your bags. **Re-plan** (confirm popup) rebuilds with current prices and replaces the list. The lock clears at the daily reset and with `/writs reset`.
- **Apply limits and lag (1.3.8):** Apply limits (or Enter in Budget gold) rebuilds a locked plan after a confirm, so a new budget actually takes effect. Re-plan reads the boxes first. Auctionator price updates no longer re-rank and re-route a locked list on every scan pulse.
- **Coin Pouch totals and averages (1.3.7):** every pouch opened during a run (and after the last turn-in, before End run) is added to the total. Per-tier averages, counts, min/max and item IDs are saved across runs and used for the #3 net estimate. `/writs pouches` shows them; `/writs pouches export` copies a one-line snapshot.
- **Owned writ Rep/g (1.3.6):** writs you already have that cost nothing to buy show a blank Rep/g in #3 (and "Already owned" on the tooltip) instead of a huge number. They still sort to the top of the plan. If a fill item still needs buying, Rep/g uses that spend.
- **Bags, AH button, and estimated net (1.3.2):** tick **Use writs in my bags** in #2 to add writs you already have (bags or bank) to the plan at no writ cost, and only shop for a missing fill item if the turn-in is routable. A compact Buy step-by-step button sits on the Auction House title bar (left of the close button on the classic AuctionFrame; `/writs ahbutton` if it is missing; `/writs buy` still works); it is disabled until the plan is locked and shows how many items are still short. #3 shows an estimated net (~ cost minus the expected Coin Pouch). Averages are learned from pouches you open after a turn-in. Only Artisan starts with a published average (74.56s, Wowhead Looter); Journeyman and Expert show ? until learned. **Rank by net gold** (optional, off by default) ranks by reputation per estimated net gold.
- **Run totals (1.3.1):** actual purchase prices are saved (Buy step by step always; other AH buys when the item hits your bags). When the last writ is turned in, a popup reminds you to open every Coin Pouch and shows how many are left. End run warns if any are still unopened, then shows actual spend, pouch gold, quest gold, net gain/loss versus the planned cost, and reputation. `/writs history` (or History on the tracker) lists the last 10 runs.
- **Buy step by step (1.3.0):** with the Auction House open and the plan locked, click **Buy step by step** in #4 (or `/writs buy`). A popup goes item by item: quantity needed, scanned price vs live price (green cheaper, red dearer), then **Accept** (buy), **Reject** (click twice: drops the writs that need it and their paired items, rebuilds the route, updates the Auctionator list), **Skip** (later) or **Stop**. Commodities buy in one click; separate listings take one click each. Live vs scanned compares what you actually pay to the planned cost for the quantity needed, not the stack's unit price. Uses C_AuctionHouse (SendSearchQuery, StartCommoditiesPurchase/ConfirmCommoditiesPurchase, PlaceBid).
- **AH shopping list** calls `Auctionator.API.v1.CreateShoppingList('WritRunner', name, searchStrings[])` (signature confirmed on Darth's installed Auctionator). Search terms are built with `ConvertToSearchString(callerID, { searchString = ..., isExact = true })` when that API exists. If CreateShoppingList is missing, WritRunner falls back to `MultiSearchExact` / `MultiSearch` (Auction House must be open).
- Your faction is detected automatically and shown with the matching reputation faction (Alliance: Azeroth Commerce Authority, Horde: Durotar Supply and Logistics). Named writs themselves are not faction-locked.

Drag the window to move it. Position is saved.

### Starting a turn-in run

1. Set **Budget gold** (for example 10) and any other filters, and wait for prices to fill.
2. Check the shopping list and the turn-in route in the main window. The route is nearest-neighbor on actual turn-in world positions where coordinates are known, starting from your current location, finishing one continent before the next (your continent first). Simple hints such as "Fly to Hillsbrad" or "Take a boat or zeppelin to Kalimdor" appear when the zone or continent changes.
3. Collect everything from the mailbox (items still in the mail are not in your bags). Click **Check bags** or `/writs check` if you want to verify first — a popup lists any missing items (or confirms that everything is in your bags) and is closed with **OK**. Then click **Start run** (or `/writs start`). If anything is missing from your bags, a popup lists each item and whether it is in the bank, in the mailbox, or not owned. The run does not start until the items are in your bags (**Check again** / **Close**). Tick **Allow starting with missing items** in #5 if you want the old **Start anyway** button. The run is a snapshot of the current plan at that moment. Changing the budget later does not alter a run already in progress; click **Restart run** to replace it.
4. A compact tracker appears. Toggle it with **Show tracker** or `/writs track`. Its position is saved separately from the main window.

### Tracker

- Steps are listed in route order: `Step N/M: Zone, NPC (coords), hand in <item>`. The current step is highlighted; finished steps are checked and greyed. Upcoming steps whose writ or required item is not in your bags are shown in red.
- Only the **next** writ is shown as a clickable item button (`SecureActionButtonTemplate`, `type=item`, `item=item:<writItemId>`). Click it when you reach that NPC to open and accept the writ, instead of accepting every writ up front (quest log and bag space). The bag count is shown on the icon. If the writ is not in your bags, the button is disabled and a hint tells you to buy or loot it first. Hover the icon for the item tooltip and a short reminder.
- Attribute changes on the secure button are queued during combat and applied on `PLAYER_REGEN_ENABLED`.
- After a turn-in the current step is checked off, the next step becomes current, the item button updates, map pins refresh, and a waypoint / super-tracked arrow is set for the next stop that has coordinates. Detection, in order:
  - `QUEST_TURNED_IN` matching the step's `questId`
  - fallback: the writ item is gone from bags **and** the required item count has dropped by at least the required amount (opening the writ alone is not enough)
  - **Skip / Mark done** on the tracker, or the daily checkbox in the main window
- Progress is saved in `WritRunnerDB` and survives `/reload` and relog. It is cleared on daily reset, **End run**, `/writs end`, or `/writs reset`.

### Map pins

Open the world map during a run. Numbered pins (1, 2, 3, …) appear for each step that has published coordinates, converted onto the map you are viewing when `C_Map` can do so. The current step is gold and slightly larger; completed steps are grey. Click a pin (or a tracker row) to set a waypoint there. The current step is also super-tracked with `C_Map.SetUserWaypoint` and `C_SuperTrack.SetSuperTrackedUserWaypoint(true)`, plus TomTom if loaded.

Minimap pins are not implemented (rotation and zoom are easy to get wrong without a pin library).

## Regenerating data

Writ item IDs, names, required items, reputation, and turn-in data live in `/workspace/writs/writs.json` and are compiled into `Data.lua`:

```
python3 /workspace/writs/gen_data.py
```

Re-run that after updating the JSON. Do not edit `Data.lua` by hand.

## Pricing notes

Prices come only from:

```lua
Auctionator.API.v1.GetAuctionPriceByItemID('WritRunner', itemId)
```

Both the writ and the required item are priced this way. The required item is multiplied by `requiredCount`. Total cost and reputation per gold are computed only when **both** prices are known. There is no vendor-price fallback and no use of the research spreadsheet's AHledger snapshot. If Auctionator has not seen an item, or Auctionator is not loaded, the value is unknown.

## Known gaps

- **Tracker, pins, and the secure writ button are untested in-game.** The ranking window and Auctionator pricing have been used in-game; this 1.1.0 path has not.
- **27 writs are unmapped** (no confirmed turn-in zone or NPC in the source data). They appear only when *Hide unconfirmed* is off, and they cannot be routed to a waypoint or pin.
- **No NPC IDs** are known. Waypoints and pins use published map coordinates (0–100 percent) when a source published them; 33 of 150 writs have coordinates. Steps without coords still appear in the tracker by zone and NPC name, with "no coords".
- **Quest IDs** come from ForeverDB and have not been confirmed against `QUEST_TURNED_IN` for every writ. If a turn-in does not auto-advance the tracker, use **Skip / Mark done**. The bag fallback can also false-positive if you destroy or vendor the required item while the writ is already out of your bags.
- **Forever map IDs** may not match Classic Era IDs (the 1414–1452 range used as a last-resort fallback). The addon walks `C_Map.GetMapChildrenInfo` at login to learn live map IDs by zone name. Riverglades in particular may have no map ID. Pins on a continent or other parent map depend on `C_Map.GetWorldPosFromMapPos` / `GetMapPosFromWorldPos`. Forever's C_Map APIs are mainline-strict about arguments: calls are pcall'd, and `GetPlayerMapPosition` is invoked as `(mapId, "player")`.
- **Secure item use** on Forever may still require a specific click registration (`AnyUp` / `AnyDown` is used, which is the usual Mainline pattern). If clicking the writ icon does nothing, try using the writ from your bags; please note that so the click handler can be adjusted.
- **Map pins** are drawn on the world-map canvas (and registered with `WorldMapFrame:AddDataProvider` when that API exists). There is no XML pin template. If pins do not appear or do not follow zoom/pan, the overlay hook may need a tweak on this client. **Minimap pins are not included.**
- Travel hints are plain-text ("Fly to X", "Take a boat or zeppelin to Kalimdor"). There is no flight-path graph.
- A few turn-in sources disagree (for example Goblin Rocket Fuel, Steel Weapon Chain, Mana Potion). The data keeps the ConquestCapped mapping where one exists and does not silently pick a winner. See the companion spreadsheet and `writs.json` notes.
- Faction is a display / reputation-label filter only. There is no separate Alliance vs Horde writ list in the source data.

## Companion files

- `/workspace/writs/writs.json` — source dataset (150 named writs).
- `/workspace/writs/WoW-Forever-Craftsmans-Writs.xlsx` — research workbook, including a Best value snapshot from AHledger (22 Nov 2026). The addon does **not** use those snapshot prices.
- `/workspace/writs/WritRunner.zip` — ready-to-install archive of this folder.
