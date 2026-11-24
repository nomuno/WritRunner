# WritRunner

Cheapest-path Craftsman's Writ reputation planner for WoW: Forever, using Auctionator prices, with a run tracker, map pins, and bag check.

**Version 1.2.1** · Interface 16001 · WoW: Forever · by Darth

## Install with WowUp

1. In WowUp, pick your WoW: Forever installation.
2. Go to **Get Addons** → **Install from URL**.
3. Paste `https://github.com/nomuno/WritRunner` and install. WowUp checks this repo's releases for updates.

## Manual install

Download `WritRunner-1.2.1-forever.zip` from the [latest release](https://github.com/nomuno/WritRunner/releases/latest) and unzip it into `World of Warcraft/_forever_/Interface/AddOns`.

## What's new in 1.2.1

- Fixed the run timer not starting on the first writ hand-in. `QUEST_TURNED_IN` was recorded by the daily-completion tracker first, which marked the step done as a "daily" update and skipped the clock. The clock now starts on the first real turn-in (quest event, bag fallback, or a daily mark that came from a turn-in), and also if you click Skip / Mark done after handing in. If a run is already past the first step with the timer still stopped, it starts at the next real turn-in.

---

This repository is published automatically from RobForge (Darth's self-hosted addon site). Changes made directly on GitHub are overwritten by the next publish.
