-- Purchase costs, Coin Pouch gold, end-of-run reminder and run history (1.3.1).
-- No StaticPopupDialogs and no combat-log registration.

local WR = WritRunner
WR.Ledger = WR.Ledger or {}
local L = WR.Ledger

-- All four Forever item IDs share the name "Coin Pouch". The amount of gold
-- inside depends on the writ tier, but the name is the same. 284584 is the
-- id listed on Forever Quest Log; 284583/284585/284586 are the other client
-- records (warcraftforever.wiki).
local KNOWN_POUCHES = {
  [284583] = true,
  [284584] = true,
  [284585] = true,
  [284586] = true,
}
local POUCH_NAME = "Coin Pouch"
local HISTORY_MAX = 10
local WINDOW = 3

-- Pouch item ID -> writ tier, only where a database lists the quests.
-- 284584 is the Journeyman reward (ForeverDB / Forever Quest Log).
-- 284585 is the Expert reward (ForeverDB: Moonsteel Broadsword, etc.).
-- 284583 and 284586 have no published quest sources, so they are only
-- attributed via a turn-in that just happened.
local POUCH_TIER = {
  [284584] = "Journeyman",
  [284585] = "Expert",
}

-- Seeded defaults used only until the player has opened a pouch of that
-- tier. Artisan is the one average both Wowhead Looter (74.56s) and
-- ConquestCapped (~75s) agree on. Journeyman and Expert are not seeded:
-- published figures conflict (Wowhead Looter Journeyman 5–19s / Expert
-- avg 36s "may be higher"; ConquestCapped Journeyman 22–45s / Expert
-- 50–90s), and Darth has no pouch samples in SavedVariables yet.
local POUCH_SEED = {
  Artisan = { copper = 7456, source = "Wowhead Looter average" },
}

local lastMoney = 0
local pouchWindowUntil = 0
local pouchesAtArm = 0
local pouchOpenedPending = 0
local pendingTiers = {} -- FIFO of writ tiers waiting for a pouch to be opened
local lastPouchCounts = {}
local buyWindowUntil = 0
local buyWindowDrop = 0
local bagsSnap = {}
local reminder, summary, history
local bagPending

local function Now()
  return (GetServerTime and GetServerTime()) or time()
end

local function Money()
  return (GetMoney and GetMoney()) or 0
end

local function After(secs, fn)
  if C_Timer and C_Timer.After then
    C_Timer.After(secs, fn)
  end
end

local function Color(text, hex)
  return "|cff" .. hex .. text .. "|r"
end

local function NetText(n)
  n = math.floor((n or 0) + 0.5)
  local sign = n >= 0 and "+" or "-"
  local body = WR.MoneyText and WR.MoneyText(math.abs(n)) or tostring(n)
  if n > 0 then
    return Color(sign .. body, "55ff55")
  end
  if n < 0 then
    return Color(sign .. body, "ff5555")
  end
  return Color(body, "cccccc")
end

local function Stamp(ts)
  ts = ts or Now()
  if date then
    return date("%a %b %d %I:%M %p", ts)
  end
  return tostring(ts)
end

------------------------------------------------------------------------
-- Daily purchase log (SavedVariables: WritRunnerDB.buyLog)
------------------------------------------------------------------------

local function Log()
  local db = WR.db
  if not db then
    return nil
  end
  local lg = db.buyLog
  if type(lg) ~= "table" or (lg.resetAt and db.resetAt and math.abs(lg.resetAt - db.resetAt) > 120) then
    lg = { resetAt = db.resetAt, bought = {}, base = {}, costs = {}, spent = 0 }
    db.buyLog = lg
  end
  lg.bought = lg.bought or {}
  lg.base = lg.base or {}
  lg.costs = lg.costs or {}
  lg.purchases = lg.purchases or {}
  lg.spent = lg.spent or 0
  return lg
end

function L.Log()
  return Log()
end

function L.RecordPurchase(itemId, qty, copper, source, cover)
  if not itemId then
    return
  end
  qty = qty or 0
  copper = copper or 0
  if qty <= 0 and copper <= 0 then
    return
  end
  local lg = Log()
  if not lg then
    return
  end
  -- `cover` is how many of the needed quantity this payment fills. A
  -- 22-stack bought to fill a need of 1 still costs the full buyout;
  -- extras are not prorated as a cheaper unit price.
  if not cover or cover < 1 then
    cover = qty
  end
  if qty > 0 and cover > qty then
    cover = qty
  end
  lg.purchases = lg.purchases or {}
  lg.purchases[itemId] = lg.purchases[itemId] or {}
  lg.purchases[itemId][#lg.purchases[itemId] + 1] = { qty = qty, copper = copper, cover = cover }
  if not lg.base[itemId] and WR.GetBagCount then
    local have = WR.GetBagCount(itemId) or 0
    -- If the item already landed in bags, back out the quantity just bought
    -- so Have() still works after a /reload.
    if have >= qty then
      lg.base[itemId] = have - qty
    else
      lg.base[itemId] = have
    end
  end
  lg.bought[itemId] = (lg.bought[itemId] or 0) + qty
  lg.costs[itemId] = (lg.costs[itemId] or 0) + copper
  lg.spent = lg.spent + copper
  if WR.Run and WR.Run.IsActive and WR.Run.IsActive() then
    local run = WR.Run.Get and WR.Run.Get()
    if run then
      run.actualSpent = (run.actualSpent or 0) + copper
    end
  end
  if WR.UI and WR.UI.Refresh and WR.UI.frame and WR.UI.frame:IsShown() and source ~= "buyer" then
    WR.UI.Refresh()
  end
end

function L.Spent()
  local lg = Log()
  return lg and lg.spent or 0
end

function L.CostOf(itemId)
  local lg = Log()
  return lg and lg.costs and lg.costs[itemId] or 0
end

-- Out-of-pocket cost of the purchases used to cover `need` of `itemId`.
-- Each listing's full buyout is counted once, in order, until the
-- quantities received cover the need. Extra items on a stack are not
-- treated as a cheaper unit price.
local function SpentToCover(lg, itemId, need)
  if not lg or not itemId or not need or need <= 0 then
    return 0, 0
  end
  local list = lg.purchases and lg.purchases[itemId]
  local got, cost, i = 0, 0
  if list and #list > 0 then
    for i = 1, #list do
      if got >= need then
        break
      end
      local p = list[i]
      cost = cost + (p.copper or 0)
      got = got + (p.qty or 0)
    end
  else
    -- Older logs with only totals: do not prorate a stack down to a
    -- unit price. The full recorded cost is the out-of-pocket spend.
    local bought = lg.bought and lg.bought[itemId] or 0
    local total = lg.costs and lg.costs[itemId] or 0
    if bought > 0 and total > 0 then
      cost = total
      got = bought
    end
  end
  local tracked = got
  if tracked > need then
    tracked = need
  end
  return cost, tracked
end

function L.SpentToCover(itemId, need)
  return SpentToCover(Log(), itemId, need)
end

-- Actual copper spent for the items a run (or plan) uses. Stack extras
-- do not dilute the cost.
function L.SpentForSteps(steps)
  local lg = Log()
  local need, spent, tracked, untracked = {}, 0, 0, 0
  local i
  for i = 1, #(steps or {}) do
    local s = steps[i]
    if s.writItemId then
      need[s.writItemId] = (need[s.writItemId] or 0) + 1
    end
    if s.requiredItemId then
      need[s.requiredItemId] = (need[s.requiredItemId] or 0) + (s.requiredCount or 1)
    end
  end
  local id, qty
  for id, qty in pairs(need) do
    local cost, use = SpentToCover(lg, id, qty)
    if use > 0 then
      spent = spent + cost
      tracked = tracked + use
      if qty > use then
        untracked = untracked + (qty - use)
      end
    else
      untracked = untracked + qty
    end
  end
  return math.floor(spent + 0.5), tracked, untracked
end

-- Same basis as the buyer: out-of-pocket for the locked shopping list
-- (item.count is the quantity the plan needs, not a stack size).
function L.SpentForShop(shop)
  local lg = Log()
  local spent, id, item = 0
  for id, item in pairs(shop or {}) do
    local qty = type(item) == "table" and (item.count or 1) or item
    local cost = SpentToCover(lg, id, qty)
    spent = spent + cost
  end
  return math.floor(spent + 0.5)
end

local function PlannedCost(steps, fallback)
  if fallback and fallback > 0 then
    return fallback
  end
  local total = 0
  local i
  for i = 1, #(steps or {}) do
    local s = steps[i]
    local writ = s.priceWrit or s.writCopper
    local fill = s.priceFill or s.itemCopper
    if (writ or fill) then
      total = total + (writ or 0) + (fill or 0)
    elseif WR.PriceWrit and s.questId and WR.Daily and WR.Daily.WritByQuestId then
      local w = WR.Daily.WritByQuestId(s.questId)
      if w then
        local p = WR.PriceWrit(w)
        total = total + (p.totalCopper or 0)
      end
    end
  end
  return total
end

------------------------------------------------------------------------
-- Coin pouches
------------------------------------------------------------------------

local function IsPouchId(id)
  if not id then
    return false
  end
  if KNOWN_POUCHES[id] then
    return true
  end
  local learned = WR.db and WR.db.learnedPouches
  return learned and learned[id] and true or false
end

function L.LearnPouch(itemId, name)
  if not itemId or KNOWN_POUCHES[itemId] then
    return
  end
  name = name or ""
  if name ~= "" and name ~= POUCH_NAME then
    return
  end
  WR.db = WR.db or {}
  WR.db.learnedPouches = WR.db.learnedPouches or {}
  if not WR.db.learnedPouches[itemId] then
    WR.db.learnedPouches[itemId] = name ~= "" and name or POUCH_NAME
  end
end

local function ItemIdFromSlot(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if ok and type(info) == "table" then
      return info.itemID or info.itemId, info.stackCount or info.quantity or 1, info.itemName or info.name
    end
  end
  if C_Container and C_Container.GetContainerItemID then
    local ok, id = pcall(C_Container.GetContainerItemID, bag, slot)
    if ok and id then
      local count = 1
      if C_Container.GetContainerItemInfo then
        local ok2, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
        if ok2 and type(info) == "table" then
          count = info.stackCount or info.quantity or 1
        end
      end
      return id, count
    end
  end
  if GetContainerItemID then
    local ok, id = pcall(GetContainerItemID, bag, slot)
    if ok and id then
      local count = 1
      if GetContainerItemInfo then
        local ok2, _, c = pcall(GetContainerItemInfo, bag, slot)
        if ok2 and type(c) == "number" then
          count = c
        end
      end
      return id, count
    end
  end
  return nil
end

local function BagSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then
    local ok, n = pcall(C_Container.GetContainerNumSlots, bag)
    if ok and type(n) == "number" then
      return n
    end
  end
  if GetContainerNumSlots then
    local ok, n = pcall(GetContainerNumSlots, bag)
    if ok and type(n) == "number" then
      return n
    end
  end
  return 0
end

local function ItemName(id)
  if C_Item and C_Item.GetItemNameByID then
    local ok, n = pcall(C_Item.GetItemNameByID, id)
    if ok and n and n ~= "" then
      return n
    end
  end
  if GetItemInfo then
    local ok, n = pcall(GetItemInfo, id)
    if ok and n and n ~= "" then
      return n
    end
  end
  return nil
end

function L.PouchCount()
  local counts, total = {}, 0
  local bag
  for bag = 0, 4 do
    local slots = BagSlots(bag)
    local slot
    for slot = 1, slots do
      local id, count, name = ItemIdFromSlot(bag, slot)
      if id then
        name = name or ItemName(id)
        if IsPouchId(id) or name == POUCH_NAME then
          if name == POUCH_NAME then
            L.LearnPouch(id, name)
          end
          counts[id] = (counts[id] or 0) + (count or 1)
          total = total + (count or 1)
        end
      end
    end
  end
  return total, counts
end

local function RunDB()
  return WR.db and WR.db.run and WR.db.run.active and WR.db.run or nil
end

local function StatsDB()
  if not WR.db then
    return nil
  end
  WR.db.pouchStats = WR.db.pouchStats or {}
  return WR.db.pouchStats
end

-- Returns copper, source ("learned" or "seed"), sample count, source label.
function L.ExpectedPouch(tier)
  if not tier then
    return nil
  end
  local st = StatsDB()
  local rec = st and st[tier]
  if rec and (rec.n or 0) > 0 and rec.sum then
    return math.floor(rec.sum / rec.n + 0.5), "learned", rec.n, "your pouches"
  end
  local seed = POUCH_SEED[tier]
  if seed then
    return seed.copper, "seed", 0, seed.source
  end
  return nil, nil, 0, nil
end

function L.RecordPouchSample(tier, copper)
  if not tier or not copper or copper <= 0 then
    return
  end
  local st = StatsDB()
  if not st then
    return
  end
  local rec = st[tier] or { sum = 0, n = 0 }
  rec.sum = (rec.sum or 0) + copper
  rec.n = (rec.n or 0) + 1
  rec.last = copper
  st[tier] = rec
end

function L.NoteTurnInTier(tier)
  if not tier then
    return
  end
  pendingTiers[#pendingTiers + 1] = tier
  -- Keep the queue short so leftover pouches from yesterday don't linger.
  while #pendingTiers > 20 do
    table.remove(pendingTiers, 1)
  end
end

local function PopPendingTier()
  if #pendingTiers == 0 then
    return nil
  end
  local t = pendingTiers[1]
  table.remove(pendingTiers, 1)
  return t
end

local function TierForPouchId(itemId)
  return itemId and POUCH_TIER[itemId] or nil
end

function L.AddPouchGold(copper, opened)
  local run = RunDB()
  if not run or not copper or copper <= 0 then
    return
  end
  run.pouchGold = (run.pouchGold or 0) + copper
  run.pouchOpened = (run.pouchOpened or 0) + (opened or 1)
  -- Attribute this gold to a writ tier when we can: prefer the Coin Pouch
  -- item id that just left the bags, else the most recent writ turn-in.
  local openedN = opened or 1
  if openedN < 1 then
    openedN = 1
  end
  local per = math.floor(copper / openedN + 0.5)
  local i
  for i = 1, openedN do
    local tier = nil
    -- Which pouch id dropped since the last snapshot?
    local id, counts
    local _, nowCounts = L.PouchCount()
    for id, was in pairs(lastPouchCounts) do
      local now = nowCounts[id] or 0
      if now < was then
        tier = TierForPouchId(id)
        break
      end
    end
    if not tier then
      tier = PopPendingTier()
    else
      -- Consume a matching pending turn-in if we have one.
      local p
      for p = 1, #pendingTiers do
        if pendingTiers[p] == tier then
          table.remove(pendingTiers, p)
          break
        end
      end
    end
    if tier then
      L.RecordPouchSample(tier, per)
    end
  end
  lastPouchCounts = select(2, L.PouchCount())
  if reminder and reminder:IsShown() then
    L.RefreshReminder()
  end
  if WR.Tracker and WR.Tracker.RefreshStats then
    WR.Tracker.RefreshStats()
  end
  if WR.UI and WR.UI.Refresh and WR.UI.frame and WR.UI.frame:IsShown() then
    -- Refresh so #3 net figures pick up a newly learned average.
    -- Don't Rebuild the plan from prices; Refresh is fine.
  end
end

function L.AddQuestGold(questId, copper)
  if not copper or copper <= 0 then
    return
  end
  local run = RunDB()
  if run then
    run.questGold = (run.questGold or 0) + copper
    if WR.Tracker and WR.Tracker.RefreshStats then
      WR.Tracker.RefreshStats()
    end
  end
end

------------------------------------------------------------------------
-- Bag snapshots (for pouch opens and outside-buyer AH purchases)
------------------------------------------------------------------------

local function SnapshotShopBags()
  bagsSnap = {}
  local steps = WR.Run and WR.Run.IsActive and WR.Run.IsActive() and WR.Run.Steps and WR.Run.Steps()
  if not steps and WR.UI and WR.UI.GetPicked then
    local picked, plan = WR.UI.GetPicked()
    local list = (plan and plan.shop) or {}
    local i
    for i = 1, #list do
      local id = list[i].itemId
      if id then
        bagsSnap[id] = WR.GetBagCount and WR.GetBagCount(id) or 0
      end
    end
    return
  end
  local i
  for i = 1, #(steps or {}) do
    local s = steps[i]
    if s.writItemId then
      bagsSnap[s.writItemId] = WR.GetBagCount and WR.GetBagCount(s.writItemId) or 0
    end
    if s.requiredItemId then
      bagsSnap[s.requiredItemId] = WR.GetBagCount and WR.GetBagCount(s.requiredItemId) or 0
    end
  end
end

local function ShopItemIds()
  local ids = {}
  local steps = WR.Run and WR.Run.IsActive and WR.Run.IsActive() and WR.Run.Steps and WR.Run.Steps()
  if steps then
    local i
    for i = 1, #steps do
      local s = steps[i]
      if s.writItemId then ids[s.writItemId] = true end
      if s.requiredItemId then ids[s.requiredItemId] = true end
    end
  end
  if WR.UI and WR.UI.GetPicked then
    local _, plan = WR.UI.GetPicked()
    local i
    for i = 1, #((plan and plan.shop) or {}) do
      if plan.shop[i].itemId then
        ids[plan.shop[i].itemId] = true
      end
    end
  end
  -- Any item already in today's log, so a leftover buy still attributes.
  local lg = Log()
  if lg then
    local id
    for id in pairs(lg.bought or {}) do
      ids[id] = true
    end
  end
  -- Known writ / fill items, so a buy before the list is locked still counts.
  if WritRunnerData then
    local i
    for i = 1, #(WritRunnerData.writs or {}) do
      local w = WritRunnerData.writs[i]
      if w.writItemId then ids[w.writItemId] = true end
      if w.requiredItemId then ids[w.requiredItemId] = true end
    end
  end
  return ids
end

local function BuyerPending()
  if not WR.Buyer or not WR.Buyer._State then
    return WR.Buyer and WR.Buyer.IsActive and WR.Buyer.IsActive()
  end
  local st = WR.Buyer._State()
  return st and st.pending and true or false
end

------------------------------------------------------------------------
-- Popups
------------------------------------------------------------------------

local function Backdrop(f)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    f:SetBackdropColor(0, 0, 0, 0.94)
  else
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.94)
  end
end

local function MakeBtn(parent, text, w, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

function L.RefreshReminder()
  if not reminder or not reminder:IsShown() then
    return
  end
  local n = L.PouchCount()
  local run = RunDB()
  local gold = run and run.pouchGold or 0
  local opened = run and run.pouchOpened or 0
  if n <= 0 then
    reminder.body:SetText("Every Coin Pouch in your bags has been opened."
      .. (gold > 0 and ("\n\nGold from pouches so far: " .. WR.MoneyText(gold)
        .. (opened > 0 and string.format("  (%d opened)", opened) or "")) or "")
      .. "\nClick End run on the tracker when you are ready for the total.")
  else
    reminder.body:SetText(string.format(
      "Open the Coin Pouches in your bags so the gold can be counted.\n\nUnopened pouches: |cffffd100%d|r\nGold from pouches so far: %s%s",
      n, WR.MoneyText(gold), opened > 0 and string.format("  (%d already opened)", opened) or ""))
  end
end

function L.ShowPouchReminder()
  if not reminder then
    local f = CreateFrame("Frame", "WritRunnerPouchReminder", UIParent, "BackdropTemplate")
    f:SetSize(420, 200)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    f:SetFrameStrata("DIALOG")
    pcall(function() f:SetToplevel(true) end)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    Backdrop(f)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -16)
    f.title:SetText("Open your Coin Pouches")
    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT", 20, -48)
    f.body:SetPoint("RIGHT", f, "RIGHT", -20, 0)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    f.body:SetSpacing(3)
    f.ok = MakeBtn(f, "OK", 90, function() f:Hide() end)
    f.ok:SetPoint("BOTTOM", f, "BOTTOM", -60, 16)
    f.endBtn = MakeBtn(f, "End run", 110, function()
      f:Hide()
      if WR.Run and WR.Run.End then
        WR.Run.End()
      end
    end)
    f.endBtn:SetPoint("BOTTOM", f, "BOTTOM", 60, 16)
    if UISpecialFrames then
      tinsert(UISpecialFrames, "WritRunnerPouchReminder")
    end
    reminder = f
  end
  reminder:Show()
  L.RefreshReminder()
end

local function LinesForRecord(rec)
  local lines = {}
  lines[#lines + 1] = string.format("%d writ%s turned in%s",
    rec.done or 0, (rec.done or 0) == 1 and "" or "s",
    rec.partial and string.format("  (of %d planned)", rec.writs or 0) or "")
  if rec.elapsed and rec.elapsed > 0 then
    local secs = math.floor(rec.elapsed)
    lines[#lines + 1] = string.format("Time %d:%02d", math.floor(secs / 60), secs % 60)
  end
  lines[#lines + 1] = "Spent on items (actual):  " .. WR.MoneyText(rec.spent or 0)
  if rec.planned and rec.planned > 0 then
    local d = (rec.spent or 0) - rec.planned
    local cmp
    if math.abs(d) < 1 then
      cmp = Color("same as planned " .. WR.MoneyText(rec.planned), "cccccc")
    elseif d < 0 then
      cmp = Color(WR.MoneyText(-d) .. " under the planned " .. WR.MoneyText(rec.planned), "55ff55")
    else
      cmp = Color(WR.MoneyText(d) .. " over the planned " .. WR.MoneyText(rec.planned), "ff5555")
    end
    lines[#lines + 1] = "  " .. cmp
  end
  if rec.spendIncomplete then
    lines[#lines + 1] = Color("  Some items were already in bags, or bought in a way that was not tracked (see /writs history).", "999999")
  end
  lines[#lines + 1] = "Gold from Coin Pouches:  " .. WR.MoneyText(rec.pouchGold or 0)
    .. (rec.pouchOpened and rec.pouchOpened > 0 and string.format("  (%d opened)", rec.pouchOpened) or "")
  if rec.unopened and rec.unopened > 0 then
    lines[#lines + 1] = Color(string.format("  %d unopened pouch%s still in bags (not counted).", rec.unopened, rec.unopened == 1 and "" or "es"), "ffd100")
  end
  lines[#lines + 1] = "Quest gold (direct):  " .. WR.MoneyText(rec.questGold or 0)
  lines[#lines + 1] = "Net:  " .. NetText(rec.net or 0)
  if rec.rep and rec.rep > 0 then
    lines[#lines + 1] = string.format("Reputation gained:  %d", rec.rep)
  end
  return lines
end

function L.BuildRecord(reason)
  local run = WR.db and WR.db.run
  local steps = (run and run.steps) or (WR.Run and WR.Run.Steps and WR.Run.Steps()) or {}
  local done, total = 0, #steps
  if WR.Run and WR.Run.Counts then
    done, total = WR.Run.Counts()
  end
  local spent, _, untracked = L.SpentForSteps(steps)
  -- If the run also tallied mid-run buys into actualSpent, SpentForSteps is
  -- the better number (prorated to this plan). Fall back if the log is empty
  -- but the run recorded something.
  if spent == 0 and run and (run.actualSpent or 0) > 0 then
    spent = run.actualSpent
  end
  local planned = PlannedCost(steps, run and run.plannedCost)
  local pouchGold = run and run.pouchGold or 0
  local questGold = run and run.questGold or 0
  local unopened = L.PouchCount()
  local rep = 0
  if run then
    if run.repAtStart and WR.Rep and WR.Rep.Value then
      local v = WR.Rep.Value()
      if v then
        rep = v - run.repAtStart
      end
    end
    if rep <= 0 then
      rep = run.repGained or 0
    end
  end
  local rec = {
    at = Now(),
    writs = total,
    done = done,
    partial = done < total,
    planned = planned,
    spent = spent,
    spendIncomplete = untracked > 0,
    pouchGold = pouchGold,
    pouchOpened = run and run.pouchOpened or 0,
    questGold = questGold,
    net = pouchGold + questGold - spent,
    rep = rep > 0 and rep or nil,
    elapsed = run and run.elapsed or 0,
    unopened = unopened,
    reason = reason,
  }
  return rec
end

function L.SaveHistory(rec)
  if not WR.db or not rec then
    return
  end
  WR.db.runHistory = WR.db.runHistory or {}
  local h = WR.db.runHistory
  h[#h + 1] = rec
  while #h > HISTORY_MAX do
    table.remove(h, 1)
  end
end

function L.ShowSummary(rec)
  rec = rec or L.BuildRecord()
  if not summary then
    local f = CreateFrame("Frame", "WritRunnerRunSummary", UIParent, "BackdropTemplate")
    f:SetSize(440, 280)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    pcall(function() f:SetToplevel(true) end)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    Backdrop(f)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -16)
    f.title:SetText("Writ run summary")
    f.when = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.when:SetPoint("TOP", f.title, "BOTTOM", 0, -2)
    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT", 22, -52)
    f.body:SetPoint("RIGHT", f, "RIGHT", -22, 0)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    f.body:SetSpacing(3)
    f.ok = MakeBtn(f, "Close", 100, function() f:Hide() end)
    f.ok:SetPoint("BOTTOM", 0, 16)
    if UISpecialFrames then
      tinsert(UISpecialFrames, "WritRunnerRunSummary")
    end
    summary = f
  end
  summary.when:SetText(Stamp(rec.at))
  summary.body:SetText(table.concat(LinesForRecord(rec), "\n"))
  summary:Show()
end

function L.ShowHistory()
  local h = WR.db and WR.db.runHistory or {}
  if #h == 0 then
    WR.Print("No finished runs yet. Complete a run and click End run to store one. The last 10 are kept.")
    return
  end
  if not history then
    local f = CreateFrame("Frame", "WritRunnerRunHistory", UIParent, "BackdropTemplate")
    f:SetSize(460, 360)
    f:SetPoint("CENTER", UIParent, "CENTER", -40, 0)
    f:SetFrameStrata("DIALOG")
    pcall(function() f:SetToplevel(true) end)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    Backdrop(f)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -16)
    f.title:SetText("Recent writ runs")
    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.body:SetPoint("TOPLEFT", 20, -42)
    f.body:SetPoint("RIGHT", f, "RIGHT", -20, 0)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    f.body:SetSpacing(2)
    f.ok = MakeBtn(f, "Close", 100, function() f:Hide() end)
    f.ok:SetPoint("BOTTOM", 0, 16)
    if UISpecialFrames then
      tinsert(UISpecialFrames, "WritRunnerRunHistory")
    end
    history = f
  end
  local blocks = {}
  local i
  for i = #h, 1, -1 do
    local rec = h[i]
    local head = string.format("|cffd4a017%d. %s|r  %s", #h - i + 1, Stamp(rec.at), NetText(rec.net or 0))
    blocks[#blocks + 1] = head .. "\n  " .. table.concat(LinesForRecord(rec), "\n  ")
  end
  history.body:SetText(table.concat(blocks, "\n\n"))
  history:Show()
end

------------------------------------------------------------------------
-- Called from Run / core
------------------------------------------------------------------------

function L.OnRunStart(picked)
  local run = RunDB()
  if not run then
    return
  end
  local planned, i = 0
  for i = 1, #(picked or {}) do
    local row = picked[i]
    if row.price and row.price.totalCopper then
      planned = planned + row.price.totalCopper
    end
  end
  run.plannedCost = planned
  run.pouchGold = 0
  run.pouchOpened = 0
  run.questGold = 0
  run.actualSpent = 0
end

function L.OnRunComplete()
  L.ShowPouchReminder()
end

function L.OnQuestTurnedIn(questId, copper)
  local writ = WR.Daily and WR.Daily.WritByQuestId and WR.Daily.WritByQuestId(questId)
  if writ then
    L.NoteTurnInTier(writ.tier)
    if type(copper) == "number" and copper > 0 then
      L.AddQuestGold(questId, copper)
    end
  end
end

function L.ConfirmEnd(reason)
  -- reason is nil for a normal End-run click.
  local unopened = L.PouchCount()
  if unopened > 0 and WR.UI and WR.UI.ShowConfirm then
    WR.UI.ShowConfirm({
      title = "Unopened Coin Pouches",
      message = string.format("You still have %d unopened Coin Pouch%s in your bags. Open them first so the gold is counted, or end the run anyway.",
        unopened, unopened == 1 and "" or "es"),
      footer = "Gold already opened is kept. Ending now leaves the unopened pouches out of the total.",
      accept = "End anyway",
      cancel = "Cancel",
      OnAccept = function()
        if WR.Run and WR.Run.Finish then
          WR.Run.Finish(reason or "ended")
        end
      end,
    })
    return true
  end
  return false
end

function L.FinishRun(reason)
  local rec = L.BuildRecord(reason)
  if rec.done and rec.done > 0 or (rec.spent or 0) > 0 or (rec.pouchGold or 0) > 0 then
    L.SaveHistory(rec)
  end
  if reason ~= "daily reset" and reason ~= "silent" then
    L.ShowSummary(rec)
  end
  if reminder then
    reminder:Hide()
  end
  return rec
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local ev = CreateFrame("Frame")
local EVENTS = {
  "PLAYER_LOGIN", "PLAYER_MONEY",
  "BAG_UPDATE", "BAG_UPDATE_DELAYED",
  "LOOT_OPENED", "LOOT_CLOSED", "CHAT_MSG_MONEY",
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "COMMODITY_PURCHASED", "AUCTION_HOUSE_PURCHASE_COMPLETED",
  "QUEST_TURNED_IN",
}
local i
for i = 1, #EVENTS do
  pcall(ev.RegisterEvent, ev, EVENTS[i])
end

local function FlushBags()
  bagPending = nil
  -- Outside-buyer purchase: a shop item landed in bags after gold dropped.
  if buyWindowUntil > 0 and (GetTime and GetTime() or 0) <= buyWindowUntil and buyWindowDrop > 0 and not BuyerPending() then
    local ids = ShopItemIds()
    local gained, onlyId, onlyQty, nKinds = {}, nil, 0, 0
    local id
    for id in pairs(ids) do
      local now = WR.GetBagCount and WR.GetBagCount(id) or 0
      local was = bagsSnap[id] or 0
      if now > was then
        nKinds = nKinds + 1
        onlyId, onlyQty = id, now - was
        gained[id] = now - was
      end
    end
    if nKinds == 1 and onlyId then
      L.RecordPurchase(onlyId, onlyQty, buyWindowDrop, "ah")
      buyWindowDrop, buyWindowUntil = 0, 0
    end
  end
  if reminder and reminder:IsShown() then
    L.RefreshReminder()
  end
end

ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
  if event == "PLAYER_LOGIN" then
    lastMoney = Money()
    lastPouchCounts = select(2, L.PouchCount())
    return
  end
  if event == "AUCTION_HOUSE_SHOW" then
    SnapshotShopBags()
    return
  end
  if event == "AUCTION_HOUSE_CLOSED" then
    buyWindowUntil, buyWindowDrop = 0, 0
    return
  end
  if event == "COMMODITY_PURCHASED" then
    -- itemID, quantity. Buyer already records its own purchases.
    if BuyerPending() then
      return
    end
    local id, qty = a1, a2 or 1
    -- The money has usually just left, or is about to. Use the drop if we
    -- have it; otherwise wait for PLAYER_MONEY and attribute then.
    if id and ShopItemIds()[id] then
      if buyWindowDrop > 0 then
        L.RecordPurchase(id, qty, buyWindowDrop, "ah")
        buyWindowDrop, buyWindowUntil = 0, 0
      else
        -- PLAYER_MONEY may fire after this. Remember the item.
        buyWindowUntil = GetTime and (GetTime() + WINDOW) or WINDOW
        bagsSnap[id] = (WR.GetBagCount and WR.GetBagCount(id) or 0) - (qty or 0)
        if bagsSnap[id] < 0 then bagsSnap[id] = 0 end
      end
    end
    return
  end
  if event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
    if BuyerPending() then
      return
    end
    -- Try to read the item from the auction id; otherwise the bag-delta path
    -- after PLAYER_MONEY will catch commodities/items that go into bags.
    local id
    if a1 and C_AuctionHouse and C_AuctionHouse.GetAuctionInfoByID then
      local ok, info = pcall(C_AuctionHouse.GetAuctionInfoByID, a1)
      if ok and type(info) == "table" then
        id = info.itemID or (info.itemKey and info.itemKey.itemID)
      end
    end
    if id and ShopItemIds()[id] and buyWindowDrop > 0 then
      L.RecordPurchase(id, 1, buyWindowDrop, "ah")
      buyWindowDrop, buyWindowUntil = 0, 0
    end
    return
  end
  if event == "QUEST_TURNED_IN" then
    -- Backup: core also calls L.OnQuestTurnedIn. Arm a pouch window in case
    -- the pouch auto-opens or lands in bags this frame.
    pouchesAtArm = L.PouchCount()
    pouchWindowUntil = GetTime and (GetTime() + WINDOW) or WINDOW
    return
  end
  if event == "PLAYER_MONEY" then
    local now = Money()
    local delta = now - (lastMoney or now)
    lastMoney = now
    local t = GetTime and GetTime() or 0
    if delta > 0 and pouchWindowUntil > 0 and t <= pouchWindowUntil then
      local opened = pouchOpenedPending
      if opened < 1 then
        opened = 1
      end
      L.AddPouchGold(delta, opened)
      pouchOpenedPending = 0
      pouchesAtArm = L.PouchCount()
      pouchWindowUntil = t + 1 -- brief tail for a second pouch
      return
    end
    if delta < 0 and not BuyerPending() then
      local ah = (WR.Buyer and WR.Buyer.IsAHOpen and WR.Buyer.IsAHOpen())
        or (AuctionFrame and AuctionFrame.IsShown and AuctionFrame:IsShown())
        or (AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown())
      if ah then
        SnapshotShopBags()
        buyWindowDrop = -delta
        buyWindowUntil = t + WINDOW
      end
    end
    return
  end
  if event == "CHAT_MSG_MONEY" or event == "LOOT_OPENED" then
    -- Only extend a window that was armed by a pouch leaving the bags.
    -- Starting one here would count any loot gold as pouch gold.
    if pouchWindowUntil > 0 then
      pouchWindowUntil = GetTime and (GetTime() + WINDOW) or WINDOW
    end
    return
  end
  if event == "LOOT_CLOSED" then
    return
  end
  if event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED" then
    -- Detect a pouch leaving bags even if we weren't armed (right-click open).
    if event == "BAG_UPDATE" then
      local n = L.PouchCount()
      -- Cheap path: if reminder is up, always refresh after a delay.
      if pouchWindowUntil == 0 then
        -- We'll compare on delayed.
      end
    end
    if bagPending then
      return
    end
    bagPending = true
    if C_Timer and C_Timer.After then
      C_Timer.After(0.15, FlushBags)
    else
      FlushBags()
    end
  end
end)

-- If a pouch count drop happens without a prior arm (player opens one),
-- FlushBags only updates the reminder. Arm the money window there too.
local oldFlush = FlushBags
FlushBags = function()
  local n, counts = L.PouchCount()
  if pouchesAtArm == 0 and pouchOpenedPending == 0 then
    -- First look: remember the count, do not treat it as an open.
    pouchesAtArm = n
    lastPouchCounts = counts
  elseif n < pouchesAtArm then
    pouchOpenedPending = pouchOpenedPending + (pouchesAtArm - n)
    pouchWindowUntil = GetTime and (GetTime() + WINDOW) or WINDOW
    pouchesAtArm = n
    -- Keep lastPouchCounts until the gold is attributed, so we still know
    -- which pouch id left the bags.
  else
    pouchesAtArm = n
    lastPouchCounts = counts
  end
  oldFlush()
end

-- Test hooks.
function L._SetMoney(v)
  lastMoney = v
end
function L._Flush()
  FlushBags()
end
function L._PouchWindow()
  return pouchWindowUntil, pouchesAtArm
end
