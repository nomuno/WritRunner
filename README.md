# WritRunner

Cheapest-path Craftsman's Writ reputation planner for WoW: Forever, using Auctionator prices, with a run tracker, map pins, and bag check.

**Version 1.2.2** · Interface 16001 · WoW: Forever · by Darth

## Install with WowUp

1. In WowUp, pick your WoW: Forever installation.
2. Go to **Get Addons** → **Install from URL**.
3. Paste `https://github.com/nomuno/WritRunner` and install. WowUp checks this repo's releases for updates.

## Manual install

Download `WritRunner-1.2.2-forever.zip` from the [latest release](https://github.com/nomuno/WritRunner/releases/latest) and unzip it into `World of Warcraft/_forever_/Interface/AddOns`.

## What's new in 1.2.2

- Faction-aware Classic travel: routes use Horde or Alliance flight points, ground runs into zones with no own-faction FP (Horde is no longer told to "Fly to Duskwood"), and zeppelin/boat crossings with realistic times. Ordering is shortest-path (Dijkstra) plus nearest-neighbor and 2-opt on those times, so a southern Eastern Kingdoms run prefers Swamp of Sorrows → run to Duskwood → Stranglethorn, then the Grom'gol zeppelin or Booty Bay boat to Kalimdor.
- `/writs reroute` rebuilds the remaining steps of an active run from your current position without losing progress. A `/reload` also reroutes the remaining steps.

---

This repository is published automatically from RobForge (Darth's self-hosted addon site). Changes made directly on GitHub are overwritten by the next publish.
