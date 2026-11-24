# WritRunner

Cheapest-path Craftsman's Writ reputation planner for WoW: Forever, using Auctionator prices, with a run tracker, map pins, and bag check.

**Version 1.3.5** · Interface 16001 · WoW: Forever · by Darth

## Install with WowUp

1. In WowUp, pick your WoW: Forever installation.
2. Go to **Get Addons** → **Install from URL**.
3. Paste `https://github.com/nomuno/WritRunner` and install. WowUp checks this repo's releases for updates.

## Manual install

Download `WritRunner-1.3.5-forever.zip` from the [latest release](https://github.com/nomuno/WritRunner/releases/latest) and unzip it into `World of Warcraft/_forever_/Interface/AddOns`.

## What's new in 1.3.5

- **Start run checks bags only.** If any writ or fill item is missing from your bags, the tracker does not start. The popup lists each missing item and where it is: in the bank, in the mailbox (last inbox scan, plus today's purchases not yet collected), or not owned, with a hint to visit the bank or mailbox and Start run again. Buttons are **Check again** and **Close**.
- A checkbox in #5, **Allow starting with missing items** (off by default, saved), restores the old **Start anyway** button.
- **Check bags** uses the same location breakdown. The locked shopping list in #4 shows compact tags such as `have 0 (bank 1, mail 1)` and ticks off only items actually in bags.
- Opening the bank or mailbox prints a one-line chat hint if a plan item is sitting there. Mail is scanned on MAIL_SHOW / MAIL_INBOX_UPDATE only while the mailbox is open (no taint, no secure hooks).

---

This repository is published automatically from RobForge (Darth's self-hosted addon site). Changes made directly on GitHub are overwritten by the next publish.
