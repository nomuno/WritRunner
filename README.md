# WritRunner

Cheapest-path Craftsman's Writ reputation planner for WoW: Forever, using Auctionator prices, with a run tracker, map pins, and bag check.

**Version 1.3.8** · Interface 16001 · WoW: Forever · by Darth

## Install with WowUp

1. In WowUp, pick your WoW: Forever installation.
2. Go to **Get Addons** → **Install from URL**.
3. Paste `https://github.com/nomuno/WritRunner` and install. WowUp checks this repo's releases for updates.

## Manual install

Download `WritRunner-1.3.8-forever.zip` from the [latest release](https://github.com/nomuno/WritRunner/releases/latest) and unzip it into `World of Warcraft/_forever_/Interface/AddOns`.

## What's new in 1.3.8

- **Apply limits honors the budget, even when the shopping list is locked.** A 5g budget no longer leaves an old 87-writ (144g+) plan in place. The lock still protects the list from Auctionator price updates while you shop, but a deliberate Apply limits (or Enter in the Budget / Max box) now asks to re-plan with the new limits, then rebuilds and relocks. Re-plan also reads the current boxes first, so the budget you just typed is the one it uses. "Limits applied" reports the plan that actually qualifies, not the frozen list.
- **Less lag during an Auctionator scan.** With the window open and the plan locked, price-database updates only flip the #4 "prices changed" banner. They no longer re-rank every writ or rebuild the 87-stop route on each pulse (that was the hitch). Unlocked refreshes are debounced to 1 second. Bag updates no longer rebuild the run tracker when no run is active.

---

This repository is published automatically from RobForge (Darth's self-hosted addon site). Changes made directly on GitHub are overwritten by the next publish.
